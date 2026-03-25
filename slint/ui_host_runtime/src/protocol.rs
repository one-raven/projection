use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, Read, Write};
use std::sync::mpsc::Receiver;

pub const UI_TO_ELIXIR_CAP: usize = 65_536;
pub const ELIXIR_TO_UI_CAP: usize = 1_048_576;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "t")]
pub enum UiEnvelope {
    #[serde(rename = "ready")]
    Ready { sid: String, capabilities: Value },
    #[serde(rename = "intent")]
    Intent {
        sid: String,
        id: u64,
        name: String,
        payload: Value,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "t")]
pub enum ElixirEnvelope {
    #[serde(rename = "render")]
    Render { sid: String, rev: u64, vm: Value },

    #[serde(rename = "patch")]
    Patch {
        sid: String,
        rev: u64,
        #[serde(default)]
        ack: Option<u64>,
        ops: Vec<PatchOp>,
    },

    #[serde(rename = "error")]
    Error {
        sid: String,
        #[serde(default)]
        rev: Option<u64>,
        code: String,
        message: String,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op")]
pub enum PatchOp {
    #[serde(rename = "replace")]
    Replace { path: String, value: Value },
    #[serde(rename = "add")]
    Add { path: String, value: Value },
    #[serde(rename = "remove")]
    Remove { path: String },
}

pub fn ready_envelope(sid: String) -> UiEnvelope {
    ready_envelope_with_reason(sid, None)
}

pub fn ready_envelope_with_reason(sid: String, reason: Option<String>) -> UiEnvelope {
    let mut caps = serde_json::json!({
        "m1": true,
        "transport": "stdio-packet-4"
    });

    if let Some(reason) = reason {
        caps["resync_reason"] = serde_json::Value::String(reason);
    }

    UiEnvelope::Ready {
        sid,
        capabilities: caps,
    }
}

pub fn intent_envelope(
    sid: String,
    id: u64,
    name: impl Into<String>,
    payload: Value,
) -> UiEnvelope {
    UiEnvelope::Intent {
        sid,
        id,
        name: name.into(),
        payload,
    }
}

pub fn writer_loop(rx: Receiver<UiEnvelope>) -> io::Result<()> {
    let stdout = io::stdout();
    let mut writer = stdout.lock();

    for envelope in rx {
        let payload = encode_ui_envelope(&envelope)?;
        write_frame(&mut writer, &payload, UI_TO_ELIXIR_CAP)?;
        writer.flush()?;
    }

    Ok(())
}

pub fn reader_loop<F>(mut on_envelope: F) -> io::Result<()>
where
    F: FnMut(ElixirEnvelope),
{
    let stdin = io::stdin();
    let mut reader = stdin.lock();

    loop {
        match read_frame(&mut reader, ELIXIR_TO_UI_CAP) {
            Ok(payload) => {
                let envelope = decode_elixir_envelope(&payload)?;
                on_envelope(envelope);
            }
            Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(err) => return Err(err),
        }
    }
}

fn encode_ui_envelope(envelope: &UiEnvelope) -> io::Result<Vec<u8>> {
    serde_json::to_vec(envelope).map_err(json_error)
}

fn decode_elixir_envelope(payload: &[u8]) -> io::Result<ElixirEnvelope> {
    serde_json::from_slice(payload).map_err(json_error)
}

fn read_frame(reader: &mut impl Read, max_payload: usize) -> io::Result<Vec<u8>> {
    let mut len_buf = [0_u8; 4];
    reader.read_exact(&mut len_buf)?;

    let len = u32::from_be_bytes(len_buf) as usize;
    if len > max_payload {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: {len} > {max_payload}"),
        ));
    }

    let mut payload = vec![0_u8; len];
    reader.read_exact(&mut payload)?;
    Ok(payload)
}

fn write_frame(writer: &mut impl Write, payload: &[u8], max_payload: usize) -> io::Result<()> {
    if payload.len() > max_payload {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: {} > {}", payload.len(), max_payload),
        ));
    }

    let len = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "payload exceeds u32"))?;

    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(payload)?;
    Ok(())
}

fn json_error(err: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    const CONTRACT_JSON: &str = include_str!("../../../priv/protocol_contract/contract.json");

    fn contract_fixture() -> Value {
        serde_json::from_str(CONTRACT_JSON).expect("valid contract fixture json")
    }

    fn decode_hex(hex: &str) -> Vec<u8> {
        let mut out = Vec::with_capacity(hex.len() / 2);
        let mut chars = hex.chars();

        while let (Some(high), Some(low)) = (chars.next(), chars.next()) {
            let high_digit = high.to_digit(16).expect("valid hex high digit");
            let low_digit = low.to_digit(16).expect("valid hex low digit");
            out.push(((high_digit << 4) | low_digit) as u8);
        }

        out
    }

    #[test]
    fn write_then_read_round_trip() {
        let payload = br#"{"t":"ready","sid":"S1"}"#;
        let mut out = Vec::new();

        write_frame(&mut out, payload, UI_TO_ELIXIR_CAP).expect("frame write");

        let mut cursor = Cursor::new(out);
        let decoded = read_frame(&mut cursor, UI_TO_ELIXIR_CAP).expect("frame read");
        assert_eq!(decoded, payload);
    }

    #[test]
    fn truncated_frame_is_rejected() {
        let data = vec![0, 0, 0, 5, b'a', b'b'];
        let mut cursor = Cursor::new(data);
        let err = read_frame(&mut cursor, UI_TO_ELIXIR_CAP).expect_err("expected eof");
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn oversized_frame_is_rejected() {
        let len = (UI_TO_ELIXIR_CAP as u32) + 1;
        let data = len.to_be_bytes().to_vec();
        let mut cursor = Cursor::new(data);
        let err = read_frame(&mut cursor, UI_TO_ELIXIR_CAP).expect_err("expected too large");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn endian_is_big_endian() {
        let payload = b"abc";
        let mut out = Vec::new();
        write_frame(&mut out, payload, UI_TO_ELIXIR_CAP).expect("frame write");
        assert_eq!(&out[0..4], &[0, 0, 0, 3]);
    }

    #[test]
    fn decodes_patch_envelope() {
        let payload = br#"{"t":"patch","sid":"S1","rev":2,"ops":[{"op":"replace","path":"/any_field","value":"value-1"}]}"#;
        let decoded = decode_elixir_envelope(payload).expect("decode patch");

        match decoded {
            ElixirEnvelope::Patch { sid, rev, ops, .. } => {
                assert_eq!(sid, "S1");
                assert_eq!(rev, 2);
                assert_eq!(ops.len(), 1);
            }
            other => panic!("expected patch, got {other:?}"),
        }
    }

    #[test]
    fn decodes_render_with_arbitrary_vm() {
        let payload = br#"{"t":"render","sid":"S1","rev":1,"vm":{"hello":"world","count":2,"items":["a","b"]}}"#;
        let decoded = decode_elixir_envelope(payload).expect("decode render");

        match decoded {
            ElixirEnvelope::Render { sid, rev, vm } => {
                assert_eq!(sid, "S1");
                assert_eq!(rev, 1);
                assert_eq!(vm["hello"], "world");
                assert_eq!(vm["count"], 2);
                assert_eq!(vm["items"][1], "b");
            }
            other => panic!("expected render, got {other:?}"),
        }
    }

    #[test]
    fn encodes_intent_envelope() {
        let encoded = encode_ui_envelope(&intent_envelope(
            "S1".to_string(),
            7,
            "ui.route.navigate",
            serde_json::json!({"to":"devices","params":{}}),
        ))
        .expect("encode intent");

        let value: Value = serde_json::from_slice(&encoded).expect("parse encoded json");
        assert_eq!(value["t"], "intent");
        assert_eq!(value["sid"], "S1");
        assert_eq!(value["id"], 7);
        assert_eq!(value["name"], "ui.route.navigate");
    }

    #[test]
    fn contract_fixture_caps_match_runtime_caps() {
        let fixture = contract_fixture();
        assert_eq!(fixture["caps"]["ui_to_elixir"], UI_TO_ELIXIR_CAP as u64);
        assert_eq!(fixture["caps"]["elixir_to_ui"], ELIXIR_TO_UI_CAP as u64);
    }

    #[test]
    fn contract_fixture_envelopes_decode_on_rust_side() {
        let fixture = contract_fixture();

        for key in ["elixir_render", "elixir_patch", "elixir_error"] {
            let payload =
                serde_json::to_vec(&fixture[key]).expect("encode contract envelope payload");
            decode_elixir_envelope(&payload)
                .unwrap_or_else(|err| panic!("fixture envelope '{key}' failed decode: {err}"));
        }
    }

    #[test]
    fn contract_fixture_ui_envelopes_match_rust_encoding_semantics() {
        let fixture = contract_fixture();

        let ready_encoded =
            encode_ui_envelope(&ready_envelope("S1".to_string())).expect("encode ready");
        let ready_value: Value = serde_json::from_slice(&ready_encoded).expect("parse ready json");
        assert_eq!(ready_value, fixture["ui_ready"]);

        let intent_encoded = encode_ui_envelope(&intent_envelope(
            "S1".to_string(),
            7,
            "ui.route.navigate",
            serde_json::json!({"to":"devices","params":{}}),
        ))
        .expect("encode intent");

        let intent_value: Value =
            serde_json::from_slice(&intent_encoded).expect("parse intent json");
        assert_eq!(intent_value, fixture["ui_intent"]);
    }

    #[test]
    fn contract_fixture_frame_sample_uses_big_endian_length_prefix() {
        let fixture = contract_fixture();
        let payload_ascii = fixture["frame_sample"]["payload_ascii"]
            .as_str()
            .expect("payload_ascii is string");
        let frame_hex = fixture["frame_sample"]["frame_hex"]
            .as_str()
            .expect("frame_hex is string");

        let frame = decode_hex(frame_hex);
        assert!(frame.len() >= 4);
        let len = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        assert_eq!(len, payload_ascii.len());
        assert_eq!(&frame[4..], payload_ascii.as_bytes());
    }
}
