//! Provider account probes. Only raw bounded responses cross into account authority.
//! Credentials remain request headers, and all errors deliberately omit transport details.
use crate::model::Result;
use aes::{
    cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit},
    Aes128,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use num_bigint::BigUint;
use reqwest::{Client, Method};
use serde_json::{json, Value};
use std::time::Duration;

const LIMIT: usize = 1024 * 1024;
const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X) gmgn-radio/0.1";
const RSA_DER: &str = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB";

fn encrypt_cbc(input: &[u8], key: &[u8; 16]) -> Vec<u8> {
    let cipher = Aes128::new(GenericArray::from_slice(key));
    let padding = 16 - input.len() % 16;
    let mut output = input.to_vec();
    output.resize(input.len() + padding, padding as u8);
    let mut previous = *b"0102030405060708";
    for block in output.chunks_exact_mut(16) {
        for (byte, iv) in block.iter_mut().zip(previous) {
            *byte ^= iv;
        }
        cipher.encrypt_block(GenericArray::from_mut_slice(block));
        previous.copy_from_slice(block);
    }
    output
}

fn weapi_form() -> Result<Vec<(String, String)>> {
    let first = STANDARD.encode(encrypt_cbc(b"{}", b"0CoJUm6Qyw8W8jud"));
    let params = STANDARD.encode(encrypt_cbc(first.as_bytes(), b"gmgnRadio2026Key"));
    // This is the original fixed provider public key; the DER integer marker
    // identifies its 1024-bit modulus, including its ASN.1 positive sign byte.
    let der = STANDARD
        .decode(RSA_DER)
        .map_err(|_| "music_account_encoding_failed")?;
    let position = der
        .windows(4)
        .position(|w| w == [2, 0x81, 0x81, 0])
        .ok_or("music_account_encoding_failed")?;
    let modulus = der
        .get(position + 4..position + 132)
        .ok_or("music_account_encoding_failed")?;
    let secret: Vec<u8> = b"gmgnRadio2026Key".iter().rev().copied().collect();
    let encrypted = BigUint::from_bytes_be(&secret)
        .modpow(&BigUint::from(65537u32), &BigUint::from_bytes_be(modulus));
    let raw = encrypted.to_bytes_be();
    if raw.len() > 128 {
        return Err("music_account_encoding_failed");
    }
    let mut enc = "00".repeat(128 - raw.len());
    for byte in raw {
        enc.push_str(&format!("{byte:02x}"));
    }
    Ok(vec![("params".into(), params), ("encSecKey".into(), enc)])
}

async fn probe(
    client: &Client,
    method: Method,
    url: &str,
    referer: &str,
    cookie: &str,
    transport: &str,
    form: Option<&[(String, String)]>,
    query: Option<&[(String, String)]>,
) -> Result<Value> {
    let mut request = client
        .request(method, url)
        .header("Cookie", cookie)
        .header("Referer", referer)
        .header("User-Agent", UA);
    if let Some(form) = form {
        request = request.form(form);
    }
    if let Some(query) = query {
        request = request.query(query);
    }
    let mut response = request
        .send()
        .await
        .map_err(|_| "music_account_transport_failed")?;
    let status = response.status().as_u16();
    if response
        .content_length()
        .is_some_and(|length| length > LIMIT as u64)
    {
        return Err("music_account_response_capacity");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "music_account_transport_failed")?
    {
        if bytes.len() + chunk.len() > LIMIT {
            return Err("music_account_response_capacity");
        }
        bytes.extend_from_slice(&chunk);
    }
    let body =
        serde_json::from_slice::<Value>(&bytes).map_err(|_| "music_account_invalid_response")?;
    Ok(json!({"transport":transport,"httpStatus":status,"body":body}))
}

pub async fn validate(provider: &str, cookie: &str) -> Result<Value> {
    validate_at(
        provider,
        cookie,
        "https://music.163.com",
        "https://c.y.qq.com",
    )
    .await
}

async fn validate_at(provider: &str, cookie: &str, netease: &str, qq: &str) -> Result<Value> {
    if cookie.is_empty() || cookie.len() > 64 * 1024 || cookie.contains(['\r', '\n', '\0']) {
        return Err("music_account_invalid_cookie");
    }
    let client = Client::builder()
        .timeout(Duration::from_secs(12))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "music_account_transport_failed")?;
    match provider {
        "netease" => {
            let form = weapi_form()?;
            let mut responses = Vec::new();
            if let Ok(response) = probe(
                &client,
                Method::POST,
                &format!("{netease}/weapi/w/nuser/account/get"),
                "https://music.163.com/",
                cookie,
                "netease-weapi",
                Some(&form),
                None,
            )
            .await
            {
                // Same early-return condition as the original client. The authority
                // still decides validity; this only avoids an unnecessary fallback.
                let profile = response["body"]
                    .get("profile")
                    .filter(|v| !v.is_null())
                    .or_else(|| response["body"]["data"].get("profile"));
                let has_profile = (200..=299)
                    .contains(&response["httpStatus"].as_u64().unwrap_or(0))
                    && profile.and_then(|p| p["userId"].as_i64()).is_some();
                responses.push(response);
                if has_profile {
                    return Ok(Value::Array(responses));
                }
            }
            responses.push(
                probe(
                    &client,
                    Method::GET,
                    &format!("{netease}/api/nuser/account/get"),
                    "https://music.163.com/",
                    cookie,
                    "netease-legacy",
                    None,
                    None,
                )
                .await?,
            );
            Ok(Value::Array(responses))
        }
        "qq-music" => {
            let values: std::collections::BTreeMap<_, _> = cookie
                .split(';')
                .filter_map(|item| item.trim().split_once('='))
                .map(|(k, v)| (k.trim(), v.trim()))
                .collect();
            let uin = ["uin", "qqmusic_uin", "wxuin", "p_uin"]
                .iter()
                .find_map(|key| values.get(key))
                .ok_or("music_account_invalid_cookie")?
                .trim_start_matches('o');
            if uin.is_empty() {
                return Err("music_account_invalid_cookie");
            }
            let query: Vec<(String, String)> = [
                ("hostuin", uin),
                ("sin", "0"),
                ("size", "50"),
                ("format", "json"),
                ("g_tk", "5381"),
                ("loginUin", uin),
                ("inCharset", "utf8"),
                ("outCharset", "utf-8"),
                ("notice", "0"),
                ("platform", "yqq.json"),
                ("needNewCode", "0"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
            Ok(json!([probe(
                &client,
                Method::GET,
                &format!("{qq}/rsc/fcgi-bin/fcg_user_created_diss"),
                "https://y.qq.com/",
                cookie,
                "qq-library",
                None,
                Some(&query)
            )
            .await?]))
        }
        _ => Err("music_account_unsupported_provider"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    #[test]
    fn encoding_preserves_original_fixed_weapi_contract() {
        let body = weapi_form().unwrap();
        assert_eq!(body[0].0, "params");
        // Independent OpenSSL AES-CBC and integer modular-exponentiation vectors.
        assert_eq!(body[0].1, "6WuTDHDM5JJqAyvDFzOSb/sqIciB2msxFllmKEUI8cE=");
        assert_eq!(STANDARD.decode(&body[0].1).unwrap().len() % 16, 0);
        assert_eq!(body[1].0, "encSecKey");
        assert_eq!(body[1].1.len(), 256);
        assert_eq!(body[1].1, "c616863531d9d20ca22f58b0ab55581c16dab2091258de50644a2d009687b2e0726ded1562c10f8ef5a95a17d324022a19c741f1dcc0019e8149a4a4c89018a2c185b90cc7d43a80168c2c7fe149cf8c85620440062eea6562c33a77055d45add8c7811466ac3e93a001c842eec26fffc7dcf2fa1f3e671ac53c9f884fd33376");
        assert!(body[1].1.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(weapi_form().unwrap(), body);
    }

    async fn fixture(
        bodies: Vec<(&'static str, &'static str)>,
    ) -> (String, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let mut requests = Vec::new();
            for (status, body) in bodies {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buffer = vec![0; 8192];
                let count = stream.read(&mut buffer).await.unwrap();
                requests.push(String::from_utf8_lossy(&buffer[..count]).to_string());
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
            requests
        });
        (url, task)
    }

    #[tokio::test]
    async fn netease_new_profile_avoids_fallback() {
        let (url, task) = fixture(vec![("200 OK", r#"{"data":{"profile":{"userId":123}}}"#)]).await;
        let response = validate_at("netease", "MUSIC_U=private-fixture", &url, &url)
            .await
            .unwrap();
        assert_eq!(response.as_array().unwrap().len(), 1);
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("POST /weapi/w/nuser/account/get"));
        assert!(requests[0]
            .to_lowercase()
            .contains("cookie: music_u=private-fixture"));
    }

    #[tokio::test]
    async fn netease_invalid_new_status_uses_original_legacy_endpoint() {
        let (url, task) = fixture(vec![
            ("200 OK", r#"{"code":301}"#),
            ("200 OK", r#"{"profile":{"userId":123}}"#),
        ])
        .await;
        let response = validate_at("netease", "MUSIC_U=private-fixture", &url, &url)
            .await
            .unwrap();
        assert_eq!(response[1]["transport"], "netease-legacy");
        assert!(task.await.unwrap()[1].starts_with("GET /api/nuser/account/get"));
    }

    #[tokio::test]
    async fn qq_probes_only_library_metadata() {
        let (url, task) = fixture(vec![("200 OK", r#"{"code":0,"data":{"disslist":[]}}"#)]).await;
        let response = validate_at("qq-music", "uin=o123; qm_keyst=private-fixture", &url, &url)
            .await
            .unwrap();
        assert_eq!(response[0]["transport"], "qq-library");
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("GET /rsc/fcgi-bin/fcg_user_created_diss?"));
        assert!(requests[0].contains("hostuin=123"));
    }

    #[tokio::test]
    async fn malformed_weapi_json_still_attempts_legacy() {
        let (url, task) = fixture(vec![
            ("200 OK", "not json"),
            ("200 OK", r#"{"profile":{"userId":123}}"#),
        ])
        .await;
        let response = validate_at("netease", "MUSIC_U=private-fixture", &url, &url)
            .await
            .unwrap();
        assert_eq!(response[0]["transport"], "netease-legacy");
        assert_eq!(task.await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn redirect_is_not_followed_and_error_does_not_expose_cookie() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let redirected = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = format!("http://{}/secret", redirected.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = vec![0; 8192];
            stream.read(&mut bytes).await.unwrap();
            stream.write_all(format!("HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        });
        assert_eq!(
            validate_at("qq-music", "uin=123;qm_keyst=private-fixture", &url, &url)
                .await
                .unwrap_err(),
            "music_account_invalid_response"
        );
        task.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), redirected.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn response_capacity_is_checked_before_reading_declared_body() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = vec![0; 8192];
            stream.read(&mut bytes).await.unwrap();
            stream
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        LIMIT + 1
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        assert_eq!(
            validate_at("qq-music", "uin=123;qm_keyst=private-fixture", &url, &url)
                .await
                .unwrap_err(),
            "music_account_response_capacity"
        );
        task.await.unwrap();
    }
}
