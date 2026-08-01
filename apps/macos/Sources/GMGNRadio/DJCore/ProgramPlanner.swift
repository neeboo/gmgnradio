import Foundation

struct ProgramBrief: Codable, Equatable, Sendable {
    let id: String
    let targetDuration: TimeInterval
    let moodTags: [String]
    let energyArc: [Double]
    let conversationMode: ConversationMode
    let immediateUserInstruction: String?
    let blockedTrackIDs: Set<String>
    let recentlySkippedTrackIDs: Set<String>

    init(
        id: String,
        targetDuration: TimeInterval,
        moodTags: [String],
        energyArc: [Double],
        conversationMode: ConversationMode,
        immediateUserInstruction: String? = nil,
        blockedTrackIDs: Set<String> = [],
        recentlySkippedTrackIDs: Set<String> = []
    ) {
        self.id = id
        self.targetDuration = targetDuration
        self.moodTags = moodTags
        self.energyArc = energyArc
        self.conversationMode = conversationMode
        self.immediateUserInstruction = immediateUserInstruction
        self.blockedTrackIDs = blockedTrackIDs
        self.recentlySkippedTrackIDs = recentlySkippedTrackIDs
    }
}

enum ProgramSlotRole: String, Codable, Sendable {
    case opener
    case build
    case peak
    case cooldown
    case closer
}

struct ProgramHostHint: Codable, Equatable, Sendable {
    let shouldTalkBefore: Bool
    let maxSentenceCount: Int
    let selectionReason: String
    let currentTrack: TrackReference
    let nextTrack: TrackReference?
    let facts: [String]
    let transitionIntent: String?
}

struct ProgramSlot: Codable, Equatable, Sendable {
    let track: MusicCandidate
    let role: ProgramSlotRole
    let hostHint: ProgramHostHint
    let visualDirection: AgentVisualDirection?

    init(
        track: MusicCandidate,
        role: ProgramSlotRole,
        hostHint: ProgramHostHint,
        visualDirection: AgentVisualDirection? = nil
    ) {
        self.track = track
        self.role = role
        self.hostHint = hostHint
        self.visualDirection = visualDirection
    }
}

struct ProgramPlan: Codable, Equatable, Sendable {
    let brief: ProgramBrief
    let slots: [ProgramSlot]
    let revision: Int
    let generatedAt: Date
    let replanAfterTrackCount: Int
    let title: String?
    let direction: String?

    init(
        brief: ProgramBrief,
        slots: [ProgramSlot],
        revision: Int,
        generatedAt: Date,
        replanAfterTrackCount: Int,
        title: String? = nil,
        direction: String? = nil
    ) {
        self.brief = brief
        self.slots = slots
        self.revision = revision
        self.generatedAt = generatedAt
        self.replanAfterTrackCount = replanAfterTrackCount
        self.title = title
        self.direction = direction
    }
}

enum ProgramPlannerError: Error, Equatable {
    case insufficientPlayableCandidates(required: Int, available: Int)
}

struct ProgramPlanner {
    private let minimumTrackCount = 5
    private let maximumTrackCount = 8

    func makePlan(
        brief: ProgramBrief,
        candidates: [MusicCandidate],
        preferredTrackIDs: [String] = [],
        showProposal: AgentShowProposal? = nil,
        revision: Int = 1,
        generatedAt: Date = Date()
    ) throws -> ProgramPlan {
        let allowed = candidates.filter {
            $0.isPlayable
                && !brief.blockedTrackIDs.contains($0.id)
                && !brief.recentlySkippedTrackIDs.contains($0.id)
        }
        guard allowed.count >= minimumTrackCount else {
            throw ProgramPlannerError.insufficientPlayableCandidates(
                required: minimumTrackCount,
                available: allowed.count
            )
        }

        let estimatedCount = Int(
            ceil(brief.targetDuration / typicalTrackDuration(allowed))
        )
        let targetCount = min(
            maximumTrackCount,
            max(minimumTrackCount, estimatedCount)
        )
        let selected = selectTracks(
            from: allowed,
            preferredTrackIDs: preferredTrackIDs,
            count: min(targetCount, allowed.count),
            brief: brief
        )
        let quiet = prefersMinimalTalk(brief)
        let proposedSlots = (showProposal?.slots ?? []).reduce(
            into: [String: AgentShowSlotProposal]()
        ) { result, slot in
            if result[slot.trackID] == nil {
                result[slot.trackID] = slot
            }
        }

        let slots = selected.indices.map { index in
            let track = selected[index]
            let proposed = proposedSlots[track.id]
            let next = selected.indices.contains(index + 1)
                ? selected[index + 1]
                : nil
            let role = slotRole(index: index, count: selected.count)
            let localTalkDecision = shouldTalk(
                at: index,
                role: role,
                mode: brief.conversationMode,
                quiet: quiet
            )
            return ProgramSlot(
                track: track,
                role: role,
                hostHint: ProgramHostHint(
                    shouldTalkBefore: quiet
                        ? localTalkDecision
                        : (
                            localTalkDecision
                                || proposed?.shouldTalkBefore == true
                        ),
                    maxSentenceCount: quiet ? 1 : 2,
                    selectionReason: proposed?.selectionReason
                        .nilIfEmpty
                        ?? selectionReason(
                            track: track,
                            brief: brief
                        ),
                    currentTrack: track.reference,
                    nextTrack: next?.reference,
                    facts: track.hostFacts,
                    transitionIntent: proposed.map(\.transitionIntent)
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? next.map {
                            transitionIntent(from: track, to: $0)
                        }
                ),
                visualDirection: proposed?.visual
            )
        }

        return ProgramPlan(
            brief: brief,
            slots: slots,
            revision: revision,
            generatedAt: generatedAt,
            replanAfterTrackCount: min(2, slots.count),
            title: showProposal?.title.nilIfEmpty,
            direction: showProposal?.direction.nilIfEmpty
        )
    }

    private func selectTracks(
        from candidates: [MusicCandidate],
        preferredTrackIDs: [String],
        count: Int,
        brief: ProgramBrief
    ) -> [MusicCandidate] {
        let candidateByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.id, $0) }
        )
        var seenIDs = Set<String>()
        var selected: [MusicCandidate] = preferredTrackIDs.compactMap { id in
            guard
                seenIDs.count < count,
                let candidate = candidateByID[id],
                seenIDs.insert(id).inserted
            else {
                return nil
            }
            return candidate
        }
        if selected.count == count {
            return selected
        }

        var remaining = candidates
            .filter { !seenIDs.contains($0.id) }

        for index in selected.count ..< count {
            let targetEnergy = energyTarget(
                at: index,
                count: count,
                arc: brief.energyArc
            )
            let recentArtists = Set(selected.suffix(2).map {
                $0.artist.lowercased()
            })
            var eligible = remaining.filter {
                !recentArtists.contains($0.artist.lowercased())
            }
            if eligible.isEmpty {
                let previousArtist = selected.last?.artist.lowercased()
                eligible = remaining.filter {
                    $0.artist.lowercased() != previousArtist
                }
            }
            if eligible.isEmpty {
                eligible = remaining
            }

            guard let best = eligible.sorted(by: {
                let lhsScore = score(
                    $0,
                    targetEnergy: targetEnergy,
                    moodTags: brief.moodTags
                )
                let rhsScore = score(
                    $1,
                    targetEnergy: targetEnergy,
                    moodTags: brief.moodTags
                )
                if lhsScore == rhsScore {
                    return $0.id < $1.id
                }
                return lhsScore > rhsScore
            }).first else {
                break
            }
            selected.append(best)
            remaining.removeAll { $0.id == best.id }
        }

        return selected
    }

    private func score(
        _ candidate: MusicCandidate,
        targetEnergy: Double,
        moodTags: [String]
    ) -> Double {
        let requestedTags = Set(moodTags.map { $0.lowercased() })
        let candidateTags = Set(candidate.moodTags.map { $0.lowercased() })
        let moodScore = requestedTags.isEmpty
            ? 0.5
            : Double(requestedTags.intersection(candidateTags).count)
                / Double(requestedTags.count)
        let energyScore = 1 - min(1, abs(candidate.energy - targetEnergy))
        return candidate.matchScore * 0.3
            + candidate.userAffinity * 0.2
            + moodScore * 0.2
            + energyScore * 0.3
    }

    private func energyTarget(
        at index: Int,
        count: Int,
        arc: [Double]
    ) -> Double {
        guard !arc.isEmpty else { return 0.5 }
        guard count > 1, arc.count > 1 else { return arc[0] }
        let progress = Double(index) / Double(count - 1)
        let arcIndex = Int(
            (progress * Double(arc.count - 1)).rounded()
        )
        return min(1, max(0, arc[arcIndex]))
    }

    private func typicalTrackDuration(
        _ candidates: [MusicCandidate]
    ) -> TimeInterval {
        let durations = candidates
            .map(\.duration)
            .filter { $0 > 30 }
            .sorted()
        guard !durations.isEmpty else { return 240 }
        return durations[durations.count / 2]
    }

    private func prefersMinimalTalk(_ brief: ProgramBrief) -> Bool {
        guard let instruction = brief.immediateUserInstruction else {
            return brief.conversationMode == .quiet
        }
        let normalized = instruction.lowercased()
        let minimalPhrases = [
            "少说", "安静", "别说", "不用介绍",
            "quiet", "less talk", "no talking"
        ]
        return brief.conversationMode == .quiet
            || minimalPhrases.contains { normalized.contains($0) }
    }

    private func shouldTalk(
        at index: Int,
        role: ProgramSlotRole,
        mode: ConversationMode,
        quiet: Bool
    ) -> Bool {
        if quiet {
            return index == 0
        }
        switch mode {
        case .quiet:
            return index == 0
        case .ambient:
            return index == 0 || role == .peak || role == .closer
        case .conversational:
            return true
        }
    }

    private func slotRole(index: Int, count: Int) -> ProgramSlotRole {
        if index == 0 { return .opener }
        if index == count - 1 { return .closer }
        let progress = Double(index) / Double(max(1, count - 1))
        if progress < 0.45 { return .build }
        if progress < 0.75 { return .peak }
        return .cooldown
    }

    private func selectionReason(
        track: MusicCandidate,
        brief: ProgramBrief
    ) -> String {
        let mood = brief.moodTags.isEmpty
            ? "当前场景"
            : brief.moodTags.joined(separator: "、")
        return "符合\(mood)，能量 \(Int(track.energy * 100))%"
    }

    private func transitionIntent(
        from current: MusicCandidate,
        to next: MusicCandidate
    ) -> String {
        let delta = next.energy - current.energy
        if delta > 0.12 { return "逐步提亮，不打断当前氛围" }
        if delta < -0.12 { return "放缓能量，让节目自然落下" }
        return "保持相近能量，延续当前质感"
    }
}

private extension MusicCandidate {
    var reference: TrackReference {
        TrackReference(id: id, title: title, artist: artist)
    }

    var hostFacts: [String] {
        var values = ["艺人：\(artist)"]
        if let album, !album.isEmpty {
            values.append("专辑：\(album)")
        }
        if let releaseYear {
            values.append("发行年份：\(releaseYear)")
        }
        if !genres.isEmpty {
            values.append("风格：\(genres.joined(separator: "、"))")
        }
        return values
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
