//! Deterministic DJ rules; provider discovery and model proposals are inputs only.
use crate::model::Result;
use serde_json::{json, Value};

pub fn daily_brief(hour: u32, id: &str, instruction: Option<&str>) -> Result<Value> {
    let (mood, arc) = match hour {
        0..=5 => (json!(["深夜", "松弛", "陪伴"]), json!([0.2, 0.35, 0.25])),
        6..=10 => (json!(["清晨", "清醒", "明亮"]), json!([0.35, 0.65, 0.55])),
        11..=17 => (json!(["白天", "专注", "流动"]), json!([0.45, 0.7, 0.55])),
        18..=23 => (json!(["夜晚", "放松", "氛围"]), json!([0.4, 0.7, 0.35])),
        _ => return Err("music_program_invalid_clock"),
    };
    Ok(
        json!({"id":id,"targetDuration":1800,"moodTags":mood,"energyArc":arc,"conversationMode":"ambient","immediateUserInstruction":instruction,"blockedTrackIDs":[],"recentlySkippedTrackIDs":[]}),
    )
}
use std::collections::HashSet;

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
fn n(v: &Value, key: &str) -> f64 {
    v[key].as_f64().unwrap_or(0.0)
}
fn a<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn strings(v: &Value, key: &str) -> HashSet<String> {
    a(v, key)
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}
fn cleaned(v: &Value, key: &str, limit: usize) -> Result<String> {
    foundation_text::prefix(&foundation_text::trim(s(v, key), false)?, limit)
}
// These are the same Foundation primitives used by the retired Swift rules.
// UTF-16 indices stay inside CoreFoundation; no scalar-count truncation or
// hand-maintained Unicode punctuation table is involved.
#[cfg(target_os = "macos")]
mod foundation_text {
    use crate::model::Result;
    use std::ffi::c_void;
    #[repr(C)]
    struct Range {
        location: isize,
        length: isize,
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            a: *const c_void,
            b: *const u8,
            n: isize,
            e: u32,
            x: u8,
        ) -> *const c_void;
        fn CFStringGetRangeOfComposedCharactersAtIndex(s: *const c_void, index: isize) -> Range;
        fn CFCharacterSetGetPredefined(kind: isize) -> *const c_void;
        fn CFCharacterSetIsLongCharacterMember(set: *const c_void, scalar: u32) -> u8;
        fn CFRelease(value: *const c_void);
    }
    pub fn trim(text: &str, punctuation: bool) -> Result<String> {
        unsafe {
            let whitespace = CFCharacterSetGetPredefined(3);
            let punctuation_set = CFCharacterSetGetPredefined(11);
            if whitespace.is_null() || punctuation_set.is_null() {
                return Err("music_program_text_unavailable");
            }
            Ok(text
                .trim_matches(|c: char| {
                    CFCharacterSetIsLongCharacterMember(whitespace, c as u32) != 0
                        || (punctuation
                            && CFCharacterSetIsLongCharacterMember(punctuation_set, c as u32) != 0)
                })
                .to_owned())
        }
    }
    pub fn prefix(text: &str, limit: usize) -> Result<String> {
        if text.is_empty() || limit == 0 {
            return Ok(String::new());
        }
        let units: Vec<u16> = text.encode_utf16().collect();
        unsafe {
            let source = CFStringCreateWithBytes(
                std::ptr::null(),
                text.as_ptr(),
                text.len() as isize,
                0x08000100,
                0,
            );
            if source.is_null() {
                return Err("music_program_text_unavailable");
            }
            let mut end = 0usize;
            for _ in 0..limit {
                if end == units.len() {
                    break;
                }
                let range = CFStringGetRangeOfComposedCharactersAtIndex(source, end as isize);
                let Some(next) = range
                    .location
                    .checked_add(range.length)
                    .and_then(|v| usize::try_from(v).ok())
                else {
                    CFRelease(source);
                    return Err("music_program_text_unavailable");
                };
                if next <= end || next > units.len() {
                    CFRelease(source);
                    return Err("music_program_text_unavailable");
                }
                end = next;
            }
            CFRelease(source);
            String::from_utf16(&units[..end]).map_err(|_| "music_program_text_unavailable")
        }
    }
}
#[cfg(not(target_os = "macos"))]
mod foundation_text {
    use crate::model::Result;
    pub fn trim(_text: &str, _punctuation: bool) -> Result<String> {
        Err("music_program_text_unavailable")
    }
    pub fn prefix(_text: &str, _limit: usize) -> Result<String> {
        Err("music_program_text_unavailable")
    }
}
fn optional(text: String) -> Value {
    if text.is_empty() {
        Value::Null
    } else {
        json!(text)
    }
}
fn reference(v: &Value) -> Value {
    json!({"id":v["id"],"title":v["title"],"artist":v["artist"]})
}

pub fn discovery(brief: &Value) -> Result<Value> {
    let mut value = prepare(brief, &[], &[])?;
    value.as_object_mut().unwrap().remove("candidates");
    Ok(value)
}

pub fn candidate_pool(knowledge: &[Value], brief: &Value, now_seconds: f64) -> Result<Value> {
    let mut excluded = strings(brief, "blockedTrackIDs");
    excluded.extend(strings(brief, "recentlySkippedTrackIDs"));
    let arc = a(brief, "energyArc");
    let target = if arc.is_empty() {
        None
    } else {
        Some(arc.iter().filter_map(Value::as_f64).sum::<f64>() / arc.len() as f64)
    };
    candidate_pool_request(
        knowledge,
        &json!({"moodTags":brief["moodTags"],"targetEnergy":target,
        "excludedTrackIDs":excluded,"limit":30,"recentSkipWindow":7.0*86400.0,"rediscoveryAge":30.0*86400.0}),
        now_seconds,
    )
}

pub fn candidate_pool_request(
    knowledge: &[Value],
    request: &Value,
    now_seconds: f64,
) -> Result<Value> {
    if !now_seconds.is_finite() {
        return Err("music_program_invalid_time");
    }
    let limit = request["limit"].as_i64().unwrap_or(30).clamp(0, 100) as usize;
    if limit == 0 {
        return Ok(json!({"items":[]}));
    }
    let excluded = strings(request, "excludedTrackIDs");
    let recent_skip_window = request["recentSkipWindow"]
        .as_f64()
        .unwrap_or(7.0 * 86400.0);
    let rediscovery_age = request["rediscoveryAge"].as_f64().unwrap_or(30.0 * 86400.0);
    let moods: HashSet<_> = a(request, "moodTags")
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_lowercase)
        .collect();
    let target = request["targetEnergy"].as_f64();
    let mut ranked: Vec<(String, usize, f64, Value)> = Vec::new();
    for track in knowledge {
        let mut sources: Vec<_> = a(track, "sources").iter().collect();
        sources.sort_by(|l, r| {
            (r["isPlayable"] == true)
                .cmp(&(l["isPlayable"] == true))
                .then_with(|| n(r, "matchScore").total_cmp(&n(l, "matchScore")))
                .then_with(|| s(l, "providerID").cmp(s(r, "providerID")))
                .then_with(|| s(l, "trackID").cmp(s(r, "trackID")))
        });
        let Some(source) = sources.first() else {
            continue;
        };
        let identity = s(track, "identity");
        if source["isPlayable"] != true
            || excluded.contains(identity)
            || excluded.contains(s(source, "trackID"))
        {
            continue;
        }
        if let Some(skipped) = track["lastSkippedAt"].as_f64() {
            let age = now_seconds - skipped;
            if age >= 0.0 && age < recent_skip_window {
                continue;
            }
        }
        let source_affinity = sources
            .iter()
            .map(|v| n(v, "userAffinity"))
            .reduce(f64::max)
            .unwrap_or(0.0);
        let affinity = (source_affinity
            + (n(track, "playCount") * 0.035).min(0.2)
            + (n(track, "completedPlayCount") * 0.025).min(0.15)
            + if track["isLiked"] == true { 0.25 } else { 0.0 }
            - (n(track, "skipCount") * 0.12).min(0.45))
        .clamp(0.0, 1.0);
        let saved = a(track, "origins").iter().any(|v| v == "saved");
        let bucket = if !saved && n(track, "playCount") <= 0.0 && track["isLiked"] != true {
            2
        } else if track["lastPlayedAt"]
            .as_f64()
            .is_none_or(|played| now_seconds - played >= rediscovery_age)
        {
            1
        } else {
            0
        };
        let tags: HashSet<_> = a(track, "moodTags")
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_lowercase)
            .collect();
        let mood = if moods.is_empty() {
            0.5
        } else {
            moods.intersection(&tags).count() as f64 / moods.len() as f64
        };
        let energy = target
            .map(|target| 1.0 - (n(track, "energy") - target).abs().min(1.0))
            .unwrap_or(0.5);
        let score = affinity * 0.4 + n(source, "matchScore") * 0.2 + mood * 0.2 + energy * 0.2;
        let mut candidate = json!({"id":source["trackID"],"providerID":source["providerID"],"source":source["source"],
            "isPlayable":source["isPlayable"],"matchScore":source["matchScore"],"userAffinity":affinity});
        for field in [
            "canonicalID",
            "title",
            "artist",
            "album",
            "duration",
            "energy",
            "moodTags",
            "genres",
            "releaseYear",
            "artworkURL",
        ] {
            candidate[field] = track[field].clone();
        }
        ranked.push((identity.to_owned(), bucket, score, candidate));
    }
    ranked.sort_by(|l, r| r.2.total_cmp(&l.2).then_with(|| l.0.cmp(&r.0)));
    let mut selected = Vec::new();
    let mut identities = HashSet::new();
    let familiar_limit = (limit as f64 * 0.60) as usize;
    let rediscovery_limit = (limit as f64 * 0.25) as usize;
    for (bucket, quota) in [
        (0, familiar_limit),
        (1, rediscovery_limit),
        (2, limit - familiar_limit - rediscovery_limit),
    ] {
        for row in ranked.iter().filter(|r| r.1 == bucket).take(quota) {
            selected.push(row);
            identities.insert(row.0.as_str());
        }
    }
    if selected.len() < limit {
        selected.extend(
            ranked
                .iter()
                .filter(|r| !identities.contains(r.0.as_str()))
                .take(limit - selected.len()),
        );
    }
    selected.sort_by(|l, r| {
        l.1.cmp(&r.1)
            .then_with(|| r.2.total_cmp(&l.2))
            .then_with(|| l.0.cmp(&r.0))
    });
    Ok(
        json!({"items":selected.iter().map(|r|json!({"candidate":r.3,"bucket":(["familiar","rediscovery","exploration"][r.1]),"score":r.2})).collect::<Vec<_>>()}),
    )
}

/// A synced playlist retains every track in source order, including unavailable
/// tracks. Playback, rather than planning, reports their availability.
pub fn playlist_plan(playlist: &Value, generated_at: &str) -> Result<Value> {
    if !playlist["id"].is_string()
        || !playlist["name"].is_string()
        || !playlist["tracks"].is_array()
    {
        return Err("music_program_invalid_playlist");
    }
    let tracks = a(playlist, "tracks");
    let name = s(playlist, "name");
    let slots: Vec<_> = tracks
        .iter()
        .enumerate()
        .map(|(index, track)| {
            let next = tracks.get(index + 1);
            let progress = index as f64 / tracks.len().saturating_sub(1).max(1) as f64;
            let role = if index == 0 {
                "opener"
            } else if index == tracks.len() - 1 {
                "closer"
            } else if progress < 0.4 {
                "build"
            } else if progress < 0.72 {
                "peak"
            } else {
                "cooldown"
            };
            let mut facts = vec![format!("艺人：{}", s(track, "artist"))];
            if !s(track, "album").is_empty() {
                facts.push(format!("专辑：{}", s(track, "album")));
            }
            let transition = next.map(|next| {
                let delta = n(next, "energy") - n(track, "energy");
                if delta > 0.12 {
                    "逐步提亮"
                } else if delta < -0.12 {
                    "自然放缓"
                } else {
                    "延续当前质感"
                }
            });
            json!({"track":track,"role":role,"visualDirection":null,"hostHint":{
            "shouldTalkBefore":index>0 && index%3==0,"maxSentenceCount":1,
            "selectionReason":format!("来自你的歌单《{name}》"),"currentTrack":reference(track),
            "nextTrack":next.map(reference),"facts":facts,"transitionIntent":transition}})
        })
        .collect();
    Ok(
        json!({"brief":{"id":playlist["id"],"targetDuration":tracks.iter().map(|t|n(t,"duration")).sum::<f64>(),
        "moodTags":[],"energyArc":tracks.iter().map(|t|n(t,"energy")).collect::<Vec<_>>(),
        "conversationMode":"ambient","immediateUserInstruction":format!("播放我的歌单《{name}》"),
        "blockedTrackIDs":[],"recentlySkippedTrackIDs":[]},"slots":slots,"revision":1,
        "generatedAt":generated_at,"replanAfterTrackCount":tracks.len().clamp(1,3),"title":name,"direction":"已同步歌单"}),
    )
}

pub fn sanitize_proposal(proposal: &Value, candidates: &[Value]) -> Result<Value> {
    if !proposal.is_object()
        || !proposal["title"].is_string()
        || !proposal["direction"].is_string()
        || !proposal["slots"].is_array()
    {
        return Err("music_program_invalid_proposal");
    }
    // Swift decoded the complete proposal before prefix/filter sanitization. Even
    // unknown tracks and slots beyond the first eight must satisfy its wire type.
    for slot in a(proposal, "slots") {
        let visual = &slot["visual"];
        if !slot.is_object()
            || ["track_id", "selection_reason", "transition_intent"]
                .iter()
                .any(|key| !slot[*key].is_string())
            || !slot["should_talk_before"].is_boolean()
            || !visual.is_object()
            || ["mood", "palette", "motion"]
                .iter()
                .any(|key| !visual[*key].is_string())
            || !visual["intensity"].as_f64().is_some_and(f64::is_finite)
        {
            return Err("music_program_invalid_proposal");
        }
    }
    let known: HashSet<_> = candidates.iter().map(|v| s(v, "id")).collect();
    let mut seen = HashSet::new();
    let slots: Vec<_> = a(proposal,"slots").iter().take(8)
        .filter(|v| known.contains(s(v,"track_id")) && seen.insert(s(v,"track_id")))
        .map(|v| { let visual=&v["visual"]; Ok(json!({"track_id":v["track_id"],"selection_reason":cleaned(v,"selection_reason",180)?,"should_talk_before":v["should_talk_before"],"transition_intent":cleaned(v,"transition_intent",180)?,"visual":{"mood":cleaned(visual,"mood",60)?,"palette":cleaned(visual,"palette",60)?,"motion":cleaned(visual,"motion",60)?,"intensity":n(visual,"intensity").clamp(0.0,1.0)}})) })
        .collect::<Result<Vec<_>>>()?;
    Ok(
        json!({"title":cleaned(proposal,"title",60)?,"direction":cleaned(proposal,"direction",240)?,"slots":slots}),
    )
}

pub fn prepare(brief: &Value, discovery: &[Value], library: &[Value]) -> Result<Value> {
    let mut seen = HashSet::new();
    let candidates: Vec<_> = discovery
        .iter()
        .chain(library)
        .filter(|v| v["isPlayable"] == true && seen.insert(s(v, "id")))
        .take(30)
        .cloned()
        .collect();
    let instruction = foundation_text::trim(s(brief, "immediateUserInstruction"), false)?;
    let query = if instruction.is_empty() {
        None
    } else {
        let lower = instruction.to_lowercase();
        if ["city pop", "citypop", "城市流行", "シティ・ポップ"]
            .iter()
            .any(|x| lower.contains(x))
        {
            Some("City Pop".to_owned())
        } else {
            let mut q = instruction.to_owned();
            for word in [
                "请给我",
                "给我",
                "帮我",
                "重新",
                "生成一个",
                "生成一份",
                "生成",
                "做一个",
                "做一份",
                "做",
                "编排",
                "排一个",
                "排一份",
                "歌单",
                "节目单",
                "的",
            ] {
                q = q.replace(word, " ");
            }
            let q = foundation_text::trim(&q, true)?;
            Some(if q.is_empty() {
                instruction.to_owned()
            } else {
                q.to_owned()
            })
        }
    };
    let mut out = json!({"candidates":candidates});
    if let Some(q) = query {
        out["discoveryQuery"] = json!(q);
    }
    let arc = a(brief, "energyArc");
    if !arc.is_empty() {
        out["targetEnergy"] =
            json!(arc.iter().filter_map(Value::as_f64).sum::<f64>() / arc.len() as f64);
    }
    Ok(out)
}

fn score(v: &Value, energy: f64, moods: &HashSet<String>) -> f64 {
    let tags: HashSet<_> = a(v, "moodTags")
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_lowercase)
        .collect();
    let mood = if moods.is_empty() {
        0.5
    } else {
        moods.intersection(&tags).count() as f64 / moods.len() as f64
    };
    n(v, "matchScore") * 0.3
        + n(v, "userAffinity") * 0.2
        + mood * 0.2
        + (1.0 - (n(v, "energy") - energy).abs().min(1.0)) * 0.3
}

pub fn plan(
    brief: &Value,
    candidates: &[Value],
    preferred_ids: &[String],
    show_proposal: Option<&Value>,
    revision: u64,
    generated_at: &str,
) -> Result<Value> {
    let blocked = strings(brief, "blockedTrackIDs");
    let skipped = strings(brief, "recentlySkippedTrackIDs");
    let mut ids = HashSet::new();
    let allowed: Vec<_> = candidates
        .iter()
        .filter(|v| {
            v["isPlayable"] == true
                && !blocked.contains(s(v, "id"))
                && !skipped.contains(s(v, "id"))
                && ids.insert(s(v, "id"))
        })
        .collect();
    if allowed.len() < 5 {
        return Err("music_program_insufficient_playable_candidates");
    }
    let mut durations: Vec<_> = allowed
        .iter()
        .map(|v| n(v, "duration"))
        .filter(|x| *x > 30.0)
        .collect();
    durations.sort_by(f64::total_cmp);
    let duration = durations.get(durations.len() / 2).copied().unwrap_or(240.0);
    let count = ((n(brief, "targetDuration") / duration).ceil() as usize)
        .clamp(5, 8)
        .min(allowed.len());
    let mut selected: Vec<&Value> = Vec::new();
    for id in preferred_ids {
        if selected.len() == count {
            break;
        }
        if let Some(v) = allowed
            .iter()
            .find(|v| s(v, "id") == id && !selected.iter().any(|t| s(t, "id") == id))
        {
            selected.push(v);
        }
    }
    let moods: HashSet<_> = a(brief, "moodTags")
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_lowercase)
        .collect();
    let arc = a(brief, "energyArc");
    while selected.len() < count {
        let index = selected.len();
        let target = if arc.is_empty() {
            0.5
        } else if arc.len() == 1 {
            arc[0].as_f64().unwrap_or(0.0)
        } else {
            arc[((index as f64 / (count - 1) as f64) * (arc.len() - 1) as f64).round() as usize]
                .as_f64()
                .unwrap_or(0.0)
                .clamp(0.0, 1.0)
        };
        let remaining: Vec<_> = allowed
            .iter()
            .copied()
            .filter(|v| !selected.iter().any(|t| s(t, "id") == s(v, "id")))
            .collect();
        let recent: HashSet<_> = selected
            .iter()
            .rev()
            .take(2)
            .map(|v| s(v, "artist").to_lowercase())
            .collect();
        let mut eligible: Vec<_> = remaining
            .iter()
            .copied()
            .filter(|v| !recent.contains(&s(v, "artist").to_lowercase()))
            .collect();
        if eligible.is_empty() {
            eligible = remaining
                .iter()
                .copied()
                .filter(|v| {
                    selected.last().is_none_or(|last| {
                        s(last, "artist").to_lowercase() != s(v, "artist").to_lowercase()
                    })
                })
                .collect();
        }
        if eligible.is_empty() {
            eligible = remaining;
        }
        eligible.sort_by(|l, r| {
            score(r, target, &moods)
                .total_cmp(&score(l, target, &moods))
                .then_with(|| s(l, "id").cmp(s(r, "id")))
        });
        selected.push(eligible[0]);
    }
    let instruction = s(brief, "immediateUserInstruction").to_lowercase();
    let quiet = s(brief, "conversationMode") == "quiet"
        || [
            "少说",
            "安静",
            "别说",
            "不用介绍",
            "quiet",
            "less talk",
            "no talking",
        ]
        .iter()
        .any(|x| instruction.contains(x));
    let mut proposal_seen = HashSet::new();
    let proposals: Vec<_> = show_proposal
        .map(|p| a(p, "slots"))
        .unwrap_or(&[])
        .iter()
        .take(8)
        .filter(|v| ids.contains(s(v, "track_id")) && proposal_seen.insert(s(v, "track_id")))
        .collect();
    let slots:Vec<_>=selected.iter().enumerate().map(|(i,track)|{
        let next=selected.get(i+1); let progress=i as f64/(count-1) as f64;
        let role=if i==0{"opener"}else if i==count-1{"closer"}else if progress<0.45{"build"}else if progress<0.75{"peak"}else{"cooldown"};
        let proposed=proposals.iter().find(|p|s(p,"track_id")==s(track,"id")).copied();
        let local=if quiet{i==0}else{match s(brief,"conversationMode"){"conversational"=>true,"ambient"=>i==0||role=="peak"||role=="closer",_=>i==0}};
        let mut facts=vec![format!("艺人：{}",s(track,"artist"))];
        if !s(track,"album").is_empty(){facts.push(format!("专辑：{}",s(track,"album")));}
        if let Some(year)=track["releaseYear"].as_i64(){facts.push(format!("发行年份：{year}"));}
        let genres:Vec<_>=a(track,"genres").iter().filter_map(Value::as_str).collect(); if !genres.is_empty(){facts.push(format!("风格：{}",genres.join("、")));}
        let reason=proposed.map(|p|cleaned(p,"selection_reason",180)).transpose()?.filter(|x|!x.is_empty()).unwrap_or_else(||{let moods:Vec<_>=a(brief,"moodTags").iter().filter_map(Value::as_str).collect();format!("符合{}，能量 {}%",if moods.is_empty(){"当前场景".to_owned()}else{moods.join("、")},(n(track,"energy")*100.0) as i64)});
        let transition=proposed.map(|p|cleaned(p,"transition_intent",180)).transpose()?.filter(|x|!x.is_empty()).map(Value::String).unwrap_or_else(||next.map(|t|{let delta=n(t,"energy")-n(track,"energy");json!(if delta>0.12{"逐步提亮，不打断当前氛围"}else if delta< -0.12{"放缓能量，让节目自然落下"}else{"保持相近能量，延续当前质感"})}).unwrap_or(Value::Null));
        let visual=proposed.map(|p| -> Result<Value> {let v=&p["visual"];Ok(json!({"mood":cleaned(v,"mood",60)?,"palette":cleaned(v,"palette",60)?,"motion":cleaned(v,"motion",60)?,"intensity":n(v,"intensity").clamp(0.0,1.0)}))}).transpose()?.unwrap_or(Value::Null);
        Ok(json!({"track":track,"role":role,"hostHint":{"shouldTalkBefore":local||(!quiet&&proposed.is_some_and(|p|p["should_talk_before"]==true)),"maxSentenceCount":if quiet{1}else{2},"selectionReason":reason,"currentTrack":reference(track),"nextTrack":next.map(|t|reference(t)),"facts":facts,"transitionIntent":transition},"visualDirection":visual}))
    }).collect::<Result<Vec<_>>>()?;
    Ok(
        json!({"brief":brief,"slots":slots,"revision":revision,"generatedAt":generated_at,"replanAfterTrackCount":2,"title":show_proposal.map(|p|cleaned(p,"title",60).map(optional)).transpose()?.unwrap_or(Value::Null),"direction":show_proposal.map(|p|cleaned(p,"direction",240).map(optional)).transpose()?.unwrap_or(Value::Null)}),
    )
}

pub fn revise(
    current: &Value,
    active_index: i64,
    proposal: &Value,
    mode: &str,
    generated_at: &str,
) -> Result<Value> {
    if !["replanUpcoming", "insertNext"].contains(&mode) {
        return Err("music_program_invalid_edit_mode");
    }
    let old = a(current, "slots");
    let mut seen = HashSet::new();
    let proposed: Vec<_> = a(proposal, "slots")
        .iter()
        .filter(|v| seen.insert(s(&v["track"], "id")))
        .cloned()
        .collect();
    let mut out = current.clone();
    let revision = current["revision"]
        .as_u64()
        .ok_or("music_program_invalid_revision")?
        .checked_add(1)
        .ok_or("music_program_invalid_revision")?;
    out["revision"] = json!(revision);
    out["generatedAt"] = json!(generated_at);
    let replan = old.is_empty() || mode == "replanUpcoming";
    let slots = if old.is_empty() {
        proposed
    } else {
        let index = active_index.max(0).min(old.len() as i64 - 1) as usize;
        let mut played = old[..=index].to_vec();
        let played_ids: HashSet<_> = played.iter().map(|v| s(&v["track"], "id")).collect();
        let upcoming: Vec<_> = proposed
            .into_iter()
            .filter(|v| !played_ids.contains(s(&v["track"], "id")))
            .collect();
        if replan {
            played.extend(upcoming);
        } else {
            let inserted = upcoming.into_iter().next();
            let id = inserted.as_ref().map(|v| s(&v["track"], "id").to_owned());
            if let Some(v) = inserted {
                played.push(v);
            }
            played.extend(
                old[index + 1..]
                    .iter()
                    .filter(|v| id.as_deref() != Some(s(&v["track"], "id")))
                    .cloned(),
            );
        }
        played
    };
    out["slots"] = json!(slots);
    if replan {
        out["replanAfterTrackCount"] = proposal["replanAfterTrackCount"].clone();
        for key in ["title", "direction"] {
            if !proposal[key].is_null() {
                out[key] = proposal[key].clone();
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn original_daily_brief_all_hours_and_boundary_arcs() {
        for hour in 0..24 {
            let value = super::daily_brief(hour, "program-private", Some("用户指令")).unwrap();
            let expected = if hour < 6 {
                ("深夜", json!([0.2, 0.35, 0.25]))
            } else if hour < 11 {
                ("清晨", json!([0.35, 0.65, 0.55]))
            } else if hour < 18 {
                ("白天", json!([0.45, 0.7, 0.55]))
            } else {
                ("夜晚", json!([0.4, 0.7, 0.35]))
            };
            assert_eq!(value["moodTags"][0], expected.0);
            assert_eq!(value["energyArc"], expected.1);
            assert_eq!(value["immediateUserInstruction"], "用户指令");
            assert_eq!(value["targetDuration"], 1800);
        }
        assert!(super::daily_brief(24, "private", None).is_err());
    }
    use super::*;
    #[cfg(target_os = "macos")]
    #[test]
    fn foundation_prefix_matches_swift_composed_character_goldens() {
        // Goldens from String(trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).
        for (input, expected) in [
            ("👩🏽‍🚀x", "👩🏽‍🚀"),
            ("e\u{301}x", "e\u{301}"),
            ("🇨🇳x", "🇨🇳"),
            ("\u{200b}x\u{200b}", "x"),
        ] {
            assert_eq!(
                cleaned(&json!({"text":input}), "text", 1).unwrap(),
                expected
            );
        }
        assert_eq!(
            cleaned(&json!({"text":"👩🏽‍🚀e\u{301}x"}), "text", 2).unwrap(),
            "👩🏽‍🚀e\u{301}"
        );
        assert_eq!(cleaned(&json!({"text":"👩🏽‍🚀"}), "text", 0).unwrap(), "");
        assert_eq!(
            cleaned(&json!({"text":"a\u{0}b"}), "text", 3).unwrap(),
            "a\u{0}b"
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn foundation_discovery_matches_swift_unicode_punctuation_goldens() {
        for (input, expected) in [
            ("⸨—«请给我爵士»—⸩", "爵士"),
            ("𐄀请给我爵士𐄀", "爵士"),
            ("𝄞请给我爵士𝄞", "𝄞 爵士𝄞"),
            ("\u{200b}请给我爵士\u{200b}", "爵士"),
            ("«请给我»", "«请给我»"),
            ("«爵—士»", "爵—士"),
        ] {
            let mut b = brief();
            b["immediateUserInstruction"] = json!(input);
            assert_eq!(
                discovery(&b).unwrap()["discoveryQuery"],
                expected,
                "{input}"
            );
        }
    }
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn foundation_unavailable_is_a_rule_error() {
        assert_eq!(
            cleaned(&json!({"text":"emoji 👩🏽‍🚀"}), "text", 1),
            Err("music_program_text_unavailable")
        );
        assert_eq!(discovery(&brief()), Err("music_program_text_unavailable"));
        assert_eq!(
            foundation_text::prefix("abc", 2),
            Err("music_program_text_unavailable")
        );
    }
    fn track(id: usize) -> Value {
        json!({"id":id.to_string(),"artist":format!("artist{}",id%3),"title":"song","isPlayable":true,"duration":240,"energy":0.5,"matchScore":0.5,"userAffinity":0.5,"moodTags":[],"genres":[]})
    }
    fn brief() -> Value {
        json!({"id":"brief","targetDuration":1200,"energyArc":[0.5],"moodTags":[],"conversationMode":"ambient","blockedTrackIDs":[],"recentlySkippedTrackIDs":[]})
    }
    #[test]
    fn prepare_discovery_first_and_city_pop() {
        let b = json!({"immediateUserInstruction":"给我城市流行歌单","energyArc":[0.2,0.8]});
        let result = prepare(&b, &[track(1)], &[track(1), track(2)]).unwrap();
        assert_eq!(result["candidates"].as_array().unwrap().len(), 2);
        assert_eq!(result["discoveryQuery"], "City Pop");
        assert_eq!(result["targetEnergy"], 0.5);
    }
    #[test]
    fn plan_count_roles_quiet_and_spacing() {
        let mut b = brief();
        b["immediateUserInstruction"] = json!("少说");
        let p = plan(
            &b,
            &(0..9).map(track).collect::<Vec<_>>(),
            &[],
            None,
            1,
            "now",
        )
        .unwrap();
        let slots = a(&p, "slots");
        assert_eq!(slots.len(), 5);
        assert_eq!(slots[0]["role"], "opener");
        assert_eq!(slots[4]["role"], "closer");
        assert_eq!(
            slots
                .iter()
                .filter(|v| v["hostHint"]["shouldTalkBefore"] == true)
                .count(),
            1
        );
        assert_ne!(slots[0]["track"]["artist"], slots[1]["track"]["artist"]);
    }
    #[test]
    fn insertion_preserves_active_and_existing_metadata() {
        let p = plan(
            &brief(),
            &(0..8).map(track).collect::<Vec<_>>(),
            &[],
            None,
            2,
            "old",
        )
        .unwrap();
        let q = plan(
            &brief(),
            &(10..18).map(track).collect::<Vec<_>>(),
            &[],
            None,
            1,
            "new",
        )
        .unwrap();
        let r = revise(&p, 1, &q, "insertNext", "later").unwrap();
        assert_eq!(r["revision"], 3);
        assert_eq!(r["slots"][0], p["slots"][0]);
        assert_eq!(r["slots"][1], p["slots"][1]);
        assert_eq!(r["slots"][2], q["slots"][0]);
        assert_eq!(a(&r, "slots").len(), 6);
    }
    #[test]
    fn rejects_insufficient() {
        assert!(plan(
            &brief(),
            &(0..4).map(track).collect::<Vec<_>>(),
            &[],
            None,
            1,
            "now"
        )
        .is_err());
    }
    #[test]
    fn duration_clamps_five_to_eight_and_blocked() {
        let tracks: Vec<_> = (0..12).map(track).collect();
        let mut b = brief();
        b["targetDuration"] = json!(10);
        assert_eq!(
            a(&plan(&b, &tracks, &[], None, 1, "now").unwrap(), "slots").len(),
            5
        );
        b["targetDuration"] = json!(10000);
        b["blockedTrackIDs"] = json!(["0"]);
        b["recentlySkippedTrackIDs"] = json!(["1"]);
        let p = plan(
            &b,
            &tracks,
            &["0".into(), "1".into(), "3".into()],
            None,
            1,
            "now",
        )
        .unwrap();
        assert_eq!(a(&p, "slots").len(), 8);
        assert_eq!(p["slots"][0]["track"]["id"], "3");
        assert!(!a(&p, "slots")
            .iter()
            .any(|v| ["0", "1"].contains(&s(&v["track"], "id"))));
    }
    #[test]
    fn proposal_prefix_precedes_filter_and_clamps() {
        let mut slots: Vec<_> = (0..9)
            .map(|i| json!({"track_id":if i==8{"1"}else{"unknown"},"selection_reason":"","transition_intent":"","should_talk_before":false,"visual":{"mood":"","palette":"","motion":"","intensity":2}}))
            .collect();
        slots[0]["track_id"] = json!("0");
        slots[0]["selection_reason"] = json!("  reason  ");
        let p = sanitize_proposal(
            &json!({"title":" title ","direction":" direction ","slots":slots}),
            &[track(0), track(1)],
        )
        .unwrap();
        assert_eq!(a(&p, "slots").len(), 1);
        assert_eq!(p["slots"][0]["visual"]["intensity"], 1.0);
        assert_eq!(p["slots"][0]["selection_reason"], "reason");
        assert_eq!(p["title"], "title");
    }
    fn proposal() -> Value {
        json!({"title":"title","direction":"direction","slots":[{"track_id":"0","selection_reason":"reason","transition_intent":"transition","should_talk_before":false,"visual":{"mood":"mood","palette":"palette","motion":"motion","intensity":0.5}}]})
    }
    #[test]
    fn proposal_rejects_missing_fields_before_filtering() {
        for field in ["title", "direction", "slots"] {
            let mut p = proposal();
            p.as_object_mut().unwrap().remove(field);
            assert_eq!(
                sanitize_proposal(&p, &[]),
                Err("music_program_invalid_proposal")
            );
        }
        for field in [
            "track_id",
            "selection_reason",
            "transition_intent",
            "should_talk_before",
            "visual",
        ] {
            let mut p = proposal();
            p["slots"][0].as_object_mut().unwrap().remove(field);
            assert!(sanitize_proposal(&p, &[]).is_err());
        }
        for field in ["mood", "palette", "motion", "intensity"] {
            let mut p = proposal();
            p["slots"][0]["visual"]
                .as_object_mut()
                .unwrap()
                .remove(field);
            assert!(sanitize_proposal(&p, &[]).is_err());
        }
    }
    #[test]
    fn proposal_rejects_wrong_boolean_string_and_visual_types() {
        for value in [json!("false"), json!(0), Value::Null] {
            let mut p = proposal();
            p["slots"][0]["should_talk_before"] = value;
            assert!(sanitize_proposal(&p, &[track(0)]).is_err());
        }
        for field in ["track_id", "selection_reason", "transition_intent"] {
            let mut p = proposal();
            p["slots"][0][field] = json!(42);
            assert!(sanitize_proposal(&p, &[track(0)]).is_err());
        }
        let mut p = proposal();
        p["slots"][0]["visual"]["intensity"] = json!("0.5");
        assert!(sanitize_proposal(&p, &[track(0)]).is_err());
        let mut p = proposal();
        p["slots"][0]["visual"] = json!([]);
        assert!(sanitize_proposal(&p, &[track(0)]).is_err());
    }
    #[test]
    fn valid_unknown_only_proposal_is_empty_for_caller_fallback() {
        let sanitized = sanitize_proposal(&proposal(), &[track(1)]).unwrap();
        assert!(a(&sanitized, "slots").is_empty());
        // No selected model slots: the authority caller uses local planning.
        let mut p = proposal();
        let slot = p["slots"][0].clone();
        p["slots"] = json!(vec![slot; 9]);
        p["slots"][8]["visual"]["motion"] = Value::Null;
        assert!(sanitize_proposal(&p, &[track(0)]).is_err());
    }
    #[test]
    fn playlist_keeps_unplayable_order_and_two_track_hints() {
        let mut first = track(0);
        first["isPlayable"] = json!(false);
        first["album"] = json!("album");
        first["releaseYear"] = json!(2000);
        first["genres"] = json!(["rock"]);
        first["energy"] = json!(0.1);
        let p = playlist_plan(
            &json!({"id":"playlist","name":"saved","tracks":[first,track(1)]}),
            "now",
        )
        .unwrap();
        assert_eq!(a(&p, "slots").len(), 2);
        assert_eq!(p["slots"][0]["track"]["isPlayable"], false);
        assert_eq!(p["slots"][0]["role"], "opener");
        assert_eq!(p["slots"][1]["role"], "closer");
        assert_eq!(p["slots"][0]["hostHint"]["nextTrack"]["id"], "1");
        assert!(p["slots"][1]["hostHint"]["nextTrack"].is_null());
        assert_eq!(
            p["slots"][0]["hostHint"]["facts"],
            json!(["艺人：artist0", "专辑：album"])
        );
        assert_eq!(p["slots"][0]["hostHint"]["transitionIntent"], "逐步提亮");
        assert_eq!(p["brief"]["targetDuration"], 480.0);
        assert_eq!(p["replanAfterTrackCount"], 2);
    }
    #[test]
    fn playlist_roles_talk_and_empty_single_counts() {
        let p = playlist_plan(
            &json!({"id":"p","name":"n","tracks":(0..8).map(track).collect::<Vec<_>>()}),
            "now",
        )
        .unwrap();
        let roles: Vec<_> = a(&p, "slots").iter().map(|v| s(v, "role")).collect();
        assert_eq!(
            roles,
            vec!["opener", "build", "build", "peak", "peak", "peak", "cooldown", "closer"]
        );
        let talking: Vec<_> = a(&p, "slots")
            .iter()
            .enumerate()
            .filter(|(_, v)| v["hostHint"]["shouldTalkBefore"] == true)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(talking, vec![3, 6]);
        assert_eq!(p["replanAfterTrackCount"], 3);
        for tracks in [json!([]), json!([track(0)])] {
            let p = playlist_plan(&json!({"id":"p","name":"n","tracks":tracks}), "now").unwrap();
            assert_eq!(p["replanAfterTrackCount"], 1);
            if !a(&p, "slots").is_empty() {
                assert_eq!(p["slots"][0]["role"], "opener");
            }
        }
    }
    fn knowledge(id: usize, bucket: usize) -> Value {
        let mut v = track(id);
        v["identity"] = json!(format!("identity{id:03}"));
        v["sources"] = json!([{"providerID":"local","trackID":id.to_string(),"source":"localLibrary","isPlayable":true,"matchScore":0.5,"userAffinity":0.2}]);
        v["origins"] = if bucket < 2 {
            json!(["saved"])
        } else {
            json!([])
        };
        v["lastPlayedAt"] = if bucket == 0 {
            json!(10000000.0)
        } else {
            Value::Null
        };
        v["playCount"] = json!(0);
        v["completedPlayCount"] = json!(0);
        v["skipCount"] = json!(0);
        v["isLiked"] = json!(false);
        v
    }
    #[test]
    fn pool_quotas_and_remaining_fill() {
        let tracks: Vec<_> = (0..90).map(|i| knowledge(i, i / 30)).collect();
        let p = candidate_pool(&tracks, &brief(), 10000000.0).unwrap();
        let rows = a(&p, "items");
        assert_eq!(rows.len(), 30);
        for (bucket, count) in [("familiar", 18), ("rediscovery", 7), ("exploration", 5)] {
            assert_eq!(rows.iter().filter(|v| v["bucket"] == bucket).count(), count);
        }
        let p = candidate_pool(
            &(0..40).map(|i| knowledge(i, 2)).collect::<Vec<_>>(),
            &brief(),
            10000000.0,
        )
        .unwrap();
        assert_eq!(a(&p, "items").len(), 30);
    }
    #[test]
    fn pool_skip_boundaries_and_exclusions() {
        let now = 10000000.0;
        let mut tracks: Vec<_> = (0..5).map(|i| knowledge(i, 2)).collect();
        tracks[0]["lastSkippedAt"] = json!(now);
        tracks[1]["lastSkippedAt"] = json!(now - 7.0 * 86400.0);
        tracks[2]["lastSkippedAt"] = json!(now + 1.0);
        let mut b = brief();
        b["blockedTrackIDs"] = json!(["identity003"]);
        b["recentlySkippedTrackIDs"] = json!(["4"]);
        let p = candidate_pool(&tracks, &b, now).unwrap();
        let ids: Vec<_> = a(&p, "items")
            .iter()
            .map(|v| s(&v["candidate"], "id"))
            .collect();
        assert_eq!(ids, vec!["1", "2"]);
    }
    #[test]
    fn pool_source_order_and_affinity_use_all_sources() {
        let mut v = knowledge(0, 2);
        v["sources"] = json!([
            {"providerID":"z","trackID":"unplayable","source":"streaming","isPlayable":false,"matchScore":1,"userAffinity":0.8},
            {"providerID":"b","trackID":"b","source":"streaming","isPlayable":true,"matchScore":0.8,"userAffinity":0},
            {"providerID":"a","trackID":"winner","source":"streaming","isPlayable":true,"matchScore":0.8,"userAffinity":0}]);
        v["playCount"] = json!(20);
        v["completedPlayCount"] = json!(20);
        v["skipCount"] = json!(20);
        v["isLiked"] = json!(true);
        let p = candidate_pool(&[v], &brief(), 10000000.0).unwrap();
        let c = &p["items"][0]["candidate"];
        assert_eq!(c["id"], "winner");
        assert!((n(c, "userAffinity") - 0.95).abs() < 1e-12);
        assert_eq!(p["items"][0]["bucket"], "rediscovery");
    }
    fn old_pool_track(id: &str, affinity: f64, match_score: f64) -> Value {
        let mut v = knowledge(0, 2);
        v["identity"] = json!(format!("metadata:title {id}|artist {id}"));
        v["title"] = json!(format!("Title {id}"));
        v["artist"] = json!(format!("Artist {id}"));
        v["sources"] = json!([{"providerID":"netease","trackID":id,"source":"streaming","isPlayable":true,"matchScore":match_score,"userAffinity":affinity}]);
        v
    }
    #[test]
    fn original_candidate_pool_excludes_recently_skipped_tracks() {
        let mut keep = old_pool_track("keep", 0.8, 0.7);
        keep["origins"] = json!(["saved"]);
        let mut skip = old_pool_track("skip", 0.9, 0.7);
        skip["origins"] = json!(["saved"]);
        skip["lastSkippedAt"] = json!(9940.0);
        skip["skipCount"] = json!(1);
        let pool = candidate_pool_request(
            &[keep, skip],
            &json!({"limit":10,"recentSkipWindow":3600}),
            10000.0,
        )
        .unwrap();
        let ids: Vec<_> = a(&pool, "items")
            .iter()
            .map(|v| s(&v["candidate"], "id"))
            .collect();
        assert_eq!(ids, vec!["keep"]);
    }
    #[test]
    fn original_candidate_pool_uses_familiar_rediscovery_exploration_buckets() {
        let now = 10000000.0;
        let mut tracks = Vec::new();
        for number in 0..6 {
            let mut v = old_pool_track(
                &format!("familiar-{number}"),
                0.9 - number as f64 * 0.01,
                0.7,
            );
            v["origins"] = json!(["saved"]);
            v["playCount"] = json!(1);
            v["completedPlayCount"] = json!(1);
            v["lastPlayedAt"] = json!(now - 86400.0);
            tracks.push(v);
        }
        for number in 0..3 {
            let mut v = old_pool_track(
                &format!("rediscovery-{number}"),
                0.7 - number as f64 * 0.01,
                0.7,
            );
            v["origins"] = json!(["saved"]);
            v["playCount"] = json!(1);
            v["completedPlayCount"] = json!(1);
            v["lastPlayedAt"] = json!(now - 60.0 * 86400.0);
            tracks.push(v);
        }
        for number in 0..4 {
            tracks.push(old_pool_track(
                &format!("explore-{number}"),
                0.2,
                0.9 - number as f64 * 0.01,
            ));
        }
        let pool = candidate_pool_request(&tracks, &json!({"limit":10}), now).unwrap();
        let items = a(&pool, "items");
        assert_eq!(items.len(), 10);
        assert_eq!(
            items.iter().filter(|v| v["bucket"] == "familiar").count(),
            6
        );
        assert_eq!(
            items
                .iter()
                .filter(|v| v["bucket"] == "rediscovery")
                .count(),
            2
        );
        assert_eq!(
            items
                .iter()
                .filter(|v| v["bucket"] == "exploration")
                .count(),
            2
        );
    }
    #[test]
    fn original_candidate_pool_is_deterministic_and_backfills_missing_buckets() {
        let mut tracks: Vec<_> = ["z", "b", "a", "c", "y", "d", "x"]
            .iter()
            .map(|id| old_pool_track(id, 0.5, 0.5))
            .collect();
        let request = json!({"limit":5});
        let first = candidate_pool_request(&tracks, &request, 10000000.0).unwrap();
        tracks.reverse();
        let second = candidate_pool_request(&tracks, &request, 10000000.0).unwrap();
        let items = a(&first, "items");
        assert_eq!(items.len(), 5);
        let ids: Vec<_> = items.iter().map(|v| s(&v["candidate"], "id")).collect();
        assert_eq!(ids, vec!["a", "b", "c", "d", "x"]);
        assert_eq!(second, first);
        assert!(items.iter().all(|v| v["bucket"] == "exploration"));
    }
}
