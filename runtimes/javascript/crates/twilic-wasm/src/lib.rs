use serde_json::Value as JsonValue;
use twilic_bridge::{
    decode_to_compact_json, decode_to_transport_json, encode_batch_compact_json,
    encode_batch_direct_from_json, encode_batch_transport_json,
    encode_batch_with_schema_transport_json, encode_bound_stream_transport_json,
    encode_compact_json, encode_direct_from_json, encode_transport_json,
    encode_with_schema_transport_json, BridgeSessionEncoder,
};
use wasm_bindgen::prelude::*;

fn into_js_error(error: impl ToString) -> JsValue {
    JsValue::from_str(&error.to_string())
}

fn parse_json_value(json: String) -> Result<JsonValue, JsValue> {
    serde_json::from_str(&json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeTransportJson)]
pub fn encode_transport_json_wasm(value_json: String) -> Result<Vec<u8>, JsValue> {
    encode_transport_json(value_json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = decodeToTransportJson)]
pub fn decode_to_transport_json_wasm(bytes: &[u8]) -> Result<String, JsValue> {
    decode_to_transport_json(bytes).map_err(into_js_error)
}

#[wasm_bindgen(js_name = decodeToCompactJson)]
pub fn decode_to_compact_json_wasm(bytes: &[u8]) -> Result<String, JsValue> {
    decode_to_compact_json(bytes).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeDirectTransportJson)]
pub fn encode_direct_transport_json_wasm(value_json: String) -> Result<Vec<u8>, JsValue> {
    let jv = parse_json_value(value_json)?;
    encode_direct_from_json(jv).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeBatchDirectTransportJson)]
pub fn encode_batch_direct_transport_json_wasm(values_json: String) -> Result<Vec<u8>, JsValue> {
    let jv = parse_json_value(values_json)?;
    encode_batch_direct_from_json(jv).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeCompactJson)]
pub fn encode_compact_json_wasm(json: String) -> Result<Vec<u8>, JsValue> {
    encode_compact_json(json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeBatchCompactJson)]
pub fn encode_batch_compact_json_wasm(json: String) -> Result<Vec<u8>, JsValue> {
    encode_batch_compact_json(json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeWithSchemaTransportJson)]
pub fn encode_with_schema_transport_json_wasm(
    schema_json: String,
    value_json: String,
) -> Result<Vec<u8>, JsValue> {
    encode_with_schema_transport_json(schema_json, value_json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeBatchTransportJson)]
pub fn encode_batch_transport_json_wasm(values_json: String) -> Result<Vec<u8>, JsValue> {
    encode_batch_transport_json(values_json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeBoundStreamTransportJson)]
pub fn encode_bound_stream_transport_json_wasm(
    schema_json: String,
    values_json: String,
) -> Result<Vec<u8>, JsValue> {
    encode_bound_stream_transport_json(schema_json, values_json).map_err(into_js_error)
}

#[wasm_bindgen(js_name = encodeBatchWithSchemaTransportJson)]
pub fn encode_batch_with_schema_transport_json_wasm(
    schema_json: String,
    values_json: String,
) -> Result<Vec<u8>, JsValue> {
    encode_batch_with_schema_transport_json(schema_json, values_json).map_err(into_js_error)
}

#[wasm_bindgen]
pub struct SessionEncoder {
    inner: BridgeSessionEncoder,
}

#[wasm_bindgen]
impl SessionEncoder {
    #[wasm_bindgen(constructor)]
    pub fn new(options_json: Option<String>) -> Result<SessionEncoder, JsValue> {
        let inner = BridgeSessionEncoder::new(options_json.as_deref()).map_err(into_js_error)?;
        Ok(Self { inner })
    }

    #[wasm_bindgen(js_name = encodeTransportJson)]
    pub fn encode_transport_json(&mut self, value_json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_transport_json(value_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeDirectTransportJson)]
    pub fn encode_direct_transport_json(&mut self, value_json: String) -> Result<Vec<u8>, JsValue> {
        let jv = parse_json_value(value_json)?;
        self.inner
            .encode_direct_from_json(jv)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeWithSchemaTransportJson)]
    pub fn encode_with_schema_transport_json(
        &mut self,
        schema_json: String,
        value_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_with_schema_transport_json(schema_json, value_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeBatchTransportJson)]
    pub fn encode_batch_transport_json(&mut self, values_json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_batch_transport_json(values_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeBoundStreamTransportJson)]
    pub fn encode_bound_stream_transport_json(
        &mut self,
        schema_json: String,
        values_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_bound_stream_transport_json(schema_json, values_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeBatchWithSchemaTransportJson)]
    pub fn encode_batch_with_schema_transport_json(
        &mut self,
        schema_json: String,
        values_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_batch_with_schema_transport_json(schema_json, values_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeBatchDirectTransportJson)]
    pub fn encode_batch_direct_transport_json(
        &mut self,
        values_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        let jv = parse_json_value(values_json)?;
        self.inner
            .encode_batch_direct_from_json(jv)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodePatchTransportJson)]
    pub fn encode_patch_transport_json(&mut self, value_json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_patch_transport_json(value_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodePatchDirectTransportJson)]
    pub fn encode_patch_direct_transport_json(
        &mut self,
        value_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        let jv = parse_json_value(value_json)?;
        self.inner
            .encode_patch_direct_from_json(jv)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeMicroBatchTransportJson)]
    pub fn encode_micro_batch_transport_json(
        &mut self,
        values_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_micro_batch_transport_json(values_json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeMicroBatchDirectTransportJson)]
    pub fn encode_micro_batch_direct_transport_json(
        &mut self,
        values_json: String,
    ) -> Result<Vec<u8>, JsValue> {
        let jv = parse_json_value(values_json)?;
        self.inner
            .encode_micro_batch_direct_from_json(jv)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeCompactJson)]
    pub fn encode_compact_json(&mut self, json: String) -> Result<Vec<u8>, JsValue> {
        self.inner.encode_compact_json(json).map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeBatchCompactJson)]
    pub fn encode_batch_compact_json(&mut self, json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_batch_compact_json(json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodePatchCompactJson)]
    pub fn encode_patch_compact_json(&mut self, json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_patch_compact_json(json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen(js_name = encodeMicroBatchCompactJson)]
    pub fn encode_micro_batch_compact_json(&mut self, json: String) -> Result<Vec<u8>, JsValue> {
        self.inner
            .encode_micro_batch_compact_json(json)
            .map_err(into_js_error)
    }

    #[wasm_bindgen]
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

#[wasm_bindgen(js_name = createSessionEncoder)]
pub fn create_session_encoder(options_json: Option<String>) -> Result<SessionEncoder, JsValue> {
    SessionEncoder::new(options_json)
}
