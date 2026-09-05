use ahash::{HashMap, HashMapExt};
use std::collections::VecDeque;

use crate::model::{Column, Message, Schema, TemplateDescriptor};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnknownReferencePolicy {
    FailFast,
    StatelessRetry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum DictionaryFallback {
    FailFast = 0,
    StatelessRetry = 1,
}

impl DictionaryFallback {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::FailFast),
            1 => Some(Self::StatelessRetry),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictionaryProfile {
    pub version: u64,
    pub hash: u64,
    pub expires_at: u64,
    pub fallback: DictionaryFallback,
}

#[derive(Debug, Clone)]
pub struct SessionOptions {
    pub max_base_snapshots: usize,
    pub enable_state_patch: bool,
    pub enable_template_batch: bool,
    pub enable_trained_dictionary: bool,
    pub unknown_reference_policy: UnknownReferencePolicy,
}

impl Default for SessionOptions {
    fn default() -> Self {
        Self {
            max_base_snapshots: 8,
            enable_state_patch: true,
            enable_template_batch: true,
            enable_trained_dictionary: true,
            unknown_reference_policy: UnknownReferencePolicy::FailFast,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct InternTable {
    pub by_value: HashMap<String, u64>,
    pub by_id: Vec<String>,
}

impl InternTable {
    pub fn get_id(&self, value: &str) -> Option<u64> {
        self.by_value.get(value).copied()
    }

    pub fn get_value(&self, id: u64) -> Option<&str> {
        self.by_id.get(id as usize).map(String::as_str)
    }

    pub fn register(&mut self, value: String) -> u64 {
        if let Some(id) = self.by_value.get(&value) {
            return *id;
        }
        let id = self.by_id.len() as u64;
        self.by_id.push(value.clone());
        self.by_value.insert(value, id);
        id
    }

    pub fn clear(&mut self) {
        self.by_value.clear();
        self.by_id.clear();
    }
}

#[derive(Debug, Clone, Default)]
pub struct ShapeTable {
    pub by_keys: HashMap<Vec<String>, u64>,
    pub by_id: HashMap<u64, Vec<String>>,
    pub observations: HashMap<Vec<String>, u64>,
    pub next_id: u64,
}

impl ShapeTable {
    pub fn get_id(&self, keys: &[String]) -> Option<u64> {
        self.by_keys.get(keys).copied()
    }

    pub fn get_keys(&self, id: u64) -> Option<&[String]> {
        self.by_id.get(&id).map(Vec::as_slice)
    }

    pub fn register(&mut self, keys: Vec<String>) -> u64 {
        if let Some(id) = self.by_keys.get(&keys) {
            return *id;
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        self.by_id.insert(id, keys.clone());
        self.by_keys.insert(keys, id);
        id
    }

    pub fn register_with_id(&mut self, shape_id: u64, keys: Vec<String>) -> bool {
        if let Some(existing) = self.by_id.get(&shape_id) {
            return existing == &keys;
        }
        if let Some(existing_id) = self.by_keys.get(&keys)
            && *existing_id != shape_id
        {
            return false;
        }
        self.by_id.insert(shape_id, keys.clone());
        self.by_keys.insert(keys, shape_id);
        self.next_id = self.next_id.max(shape_id.saturating_add(1));
        true
    }

    pub fn observe(&mut self, keys: &[String]) -> u64 {
        let count = self.observations.entry(keys.to_vec()).or_insert(0);
        *count += 1;
        *count
    }

    pub fn clear(&mut self) {
        self.by_keys.clear();
        self.by_id.clear();
        self.observations.clear();
        self.next_id = 0;
    }
}

#[derive(Debug, Clone)]
pub struct SessionState {
    pub options: SessionOptions,
    pub key_table: InternTable,
    pub string_table: InternTable,
    pub shape_table: ShapeTable,
    pub encode_shape_observations: HashMap<Vec<String>, u64>,
    pub base_snapshots: VecDeque<(u64, Message)>,
    pub templates: HashMap<u64, TemplateDescriptor>,
    pub template_columns: HashMap<u64, Vec<Column>>,
    pub field_enums: HashMap<String, Vec<String>>,
    pub dictionaries: HashMap<u64, Vec<u8>>,
    pub dictionary_profiles: HashMap<u64, DictionaryProfile>,
    pub schemas: HashMap<u64, Schema>,
    pub last_schema_id: Option<u64>,
    pub previous_message: Option<Message>,
    pub previous_message_size: Option<usize>,
    pub next_base_id: u64,
    pub next_template_id: u64,
    pub next_dictionary_id: u64,
}

impl Default for SessionState {
    fn default() -> Self {
        Self {
            options: SessionOptions::default(),
            key_table: InternTable::default(),
            string_table: InternTable::default(),
            shape_table: ShapeTable::default(),
            encode_shape_observations: HashMap::new(),
            base_snapshots: VecDeque::new(),
            templates: HashMap::new(),
            template_columns: HashMap::new(),
            field_enums: HashMap::new(),
            dictionaries: HashMap::new(),
            dictionary_profiles: HashMap::new(),
            schemas: HashMap::new(),
            last_schema_id: None,
            previous_message: None,
            previous_message_size: None,
            next_base_id: 0,
            next_template_id: 0,
            next_dictionary_id: 0,
        }
    }
}

impl SessionState {
    pub fn with_options(options: SessionOptions) -> Self {
        Self {
            options,
            ..Self::default()
        }
    }

    pub fn register_base_snapshot(&mut self, base_id: u64, message: Message) {
        self.base_snapshots.retain(|(id, _)| *id != base_id);
        self.base_snapshots.push_back((base_id, message));
        while self.base_snapshots.len() > self.options.max_base_snapshots {
            self.base_snapshots.pop_front();
        }
    }

    pub fn allocate_base_id(&mut self) -> u64 {
        let id = self.next_base_id;
        self.next_base_id = self.next_base_id.saturating_add(1);
        id
    }

    pub fn allocate_template_id(&mut self) -> u64 {
        let id = self.next_template_id;
        self.next_template_id = self.next_template_id.saturating_add(1);
        id
    }

    pub fn allocate_dictionary_id(&mut self) -> u64 {
        let id = self.next_dictionary_id;
        self.next_dictionary_id = self.next_dictionary_id.saturating_add(1);
        id
    }

    pub fn get_base_snapshot(&self, base_id: u64) -> Option<&Message> {
        self.base_snapshots
            .iter()
            .find(|(id, _)| *id == base_id)
            .map(|(_, msg)| msg)
    }

    pub fn reset_tables(&mut self) {
        self.key_table.clear();
        self.string_table.clear();
        self.shape_table.clear();
        self.encode_shape_observations.clear();
        self.field_enums.clear();
    }

    pub fn reset_state(&mut self) {
        self.reset_tables();
        self.base_snapshots.clear();
        self.templates.clear();
        self.template_columns.clear();
        self.dictionaries.clear();
        self.dictionary_profiles.clear();
        self.schemas.clear();
        self.last_schema_id = None;
        self.previous_message = None;
        self.previous_message_size = None;
        self.next_base_id = 0;
        self.next_template_id = 0;
        self.next_dictionary_id = 0;
    }
}
