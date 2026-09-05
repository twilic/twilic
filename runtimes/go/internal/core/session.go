package core

type UnknownReferencePolicy int

const (
	UnknownReferencePolicyFailFast UnknownReferencePolicy = iota
	UnknownReferencePolicyStatelessRetry
)

type DictionaryFallback int

const (
	DictionaryFallbackFailFast DictionaryFallback = iota
	DictionaryFallbackStatelessRetry
)

func dictionaryFallbackFromByte(b byte) (DictionaryFallback, bool) {
	switch b {
	case 0:
		return DictionaryFallbackFailFast, true
	case 1:
		return DictionaryFallbackStatelessRetry, true
	default:
		return 0, false
	}
}

type DictionaryProfile struct {
	Version   uint64
	Hash      uint64
	ExpiresAt uint64
	Fallback  DictionaryFallback
}

type SessionOptions struct {
	MaxBaseSnapshots        int
	EnableStatePatch        bool
	EnableTemplateBatch     bool
	EnableTrainedDictionary bool
	UnknownReferencePolicy  UnknownReferencePolicy
}

func DefaultSessionOptions() SessionOptions {
	return SessionOptions{
		MaxBaseSnapshots:        8,
		EnableStatePatch:        true,
		EnableTemplateBatch:     true,
		EnableTrainedDictionary: true,
		UnknownReferencePolicy:  UnknownReferencePolicyFailFast,
	}
}

type InternTable struct {
	ByValue map[string]uint64
	ByID    []string
}

func newInternTable() *InternTable {
	return &InternTable{ByValue: make(map[string]uint64)}
}

func (t *InternTable) GetID(value string) (uint64, bool) {
	id, ok := t.ByValue[value]
	return id, ok
}

func (t *InternTable) GetValue(id uint64) (string, bool) {
	if int(id) >= len(t.ByID) {
		return "", false
	}
	return t.ByID[id], true
}

func (t *InternTable) Register(value string) uint64 {
	if id, ok := t.ByValue[value]; ok {
		return id
	}
	id := uint64(len(t.ByID))
	t.ByID = append(t.ByID, value)
	t.ByValue[value] = id
	return id
}

func (t *InternTable) Clear() {
	t.ByValue = make(map[string]uint64)
	t.ByID = nil
}

type ShapeTable struct {
	ByKeys       map[string]uint64
	ByID         map[uint64][]string
	Observations map[string]uint64
	NextID       uint64
}

func newShapeTable() *ShapeTable {
	return &ShapeTable{
		ByKeys:       make(map[string]uint64),
		ByID:         make(map[uint64][]string),
		Observations: make(map[string]uint64),
	}
}

func shapeKey(keys []string) string {
	// stable key from ordered field names
	var b []byte
	for i, k := range keys {
		if i > 0 {
			b = append(b, 0)
		}
		b = append(b, k...)
	}
	return string(b)
}

func (t *ShapeTable) GetID(keys []string) (uint64, bool) {
	id, ok := t.ByKeys[shapeKey(keys)]
	return id, ok
}

func (t *ShapeTable) GetKeys(id uint64) ([]string, bool) {
	keys, ok := t.ByID[id]
	return keys, ok
}

func (t *ShapeTable) Register(keys []string) uint64 {
	sk := shapeKey(keys)
	if id, ok := t.ByKeys[sk]; ok {
		return id
	}
	id := t.NextID
	t.NextID++
	keysCopy := append([]string(nil), keys...)
	t.ByID[id] = keysCopy
	t.ByKeys[sk] = id
	return id
}

func (t *ShapeTable) RegisterWithID(shapeID uint64, keys []string) bool {
	sk := shapeKey(keys)
	if existing, ok := t.ByID[shapeID]; ok {
		return shapeKey(existing) == sk
	}
	if existingID, ok := t.ByKeys[sk]; ok && existingID != shapeID {
		return false
	}
	keysCopy := append([]string(nil), keys...)
	t.ByID[shapeID] = keysCopy
	t.ByKeys[sk] = shapeID
	if shapeID+1 > t.NextID {
		t.NextID = shapeID + 1
	}
	return true
}

func (t *ShapeTable) Observe(keys []string) uint64 {
	sk := shapeKey(keys)
	t.Observations[sk]++
	return t.Observations[sk]
}

func (t *ShapeTable) Clear() {
	t.ByKeys = make(map[string]uint64)
	t.ByID = make(map[uint64][]string)
	t.Observations = make(map[string]uint64)
	t.NextID = 0
}

type baseSnapshotEntry struct {
	ID      uint64
	Message Message
}

type SessionState struct {
	Options                 SessionOptions
	KeyTable                *InternTable
	StringTable             *InternTable
	ShapeTable              *ShapeTable
	EncodeShapeObservations map[string]uint64
	BaseSnapshots           []baseSnapshotEntry
	Templates               map[uint64]TemplateDescriptor
	TemplateColumns         map[uint64][]Column
	FieldEnums              map[string][]string
	Dictionaries            map[uint64][]byte
	DictionaryProfiles      map[uint64]DictionaryProfile
	Schemas                 map[uint64]Schema
	LastSchemaID            *uint64
	PreviousMessage         *Message
	PreviousMessageSize     *int
	NextBaseID              uint64
	NextTemplateID          uint64
	NextDictionaryID        uint64
}

func newSessionState() *SessionState {
	return &SessionState{
		Options:                 DefaultSessionOptions(),
		KeyTable:                newInternTable(),
		StringTable:             newInternTable(),
		ShapeTable:              newShapeTable(),
		EncodeShapeObservations: make(map[string]uint64),
		Templates:               make(map[uint64]TemplateDescriptor),
		TemplateColumns:         make(map[uint64][]Column),
		FieldEnums:              make(map[string][]string),
		Dictionaries:            make(map[uint64][]byte),
		DictionaryProfiles:      make(map[uint64]DictionaryProfile),
		Schemas:                 make(map[uint64]Schema),
	}
}

func newSessionStateWithOptions(options SessionOptions) *SessionState {
	s := newSessionState()
	s.Options = options
	return s
}

func (s *SessionState) RegisterBaseSnapshot(baseID uint64, message Message) {
	filtered := make([]baseSnapshotEntry, 0, len(s.BaseSnapshots))
	for _, e := range s.BaseSnapshots {
		if e.ID != baseID {
			filtered = append(filtered, e)
		}
	}
	filtered = append(filtered, baseSnapshotEntry{ID: baseID, Message: message.Clone()})
	for len(filtered) > s.Options.MaxBaseSnapshots {
		filtered = filtered[1:]
	}
	s.BaseSnapshots = filtered
}

func (s *SessionState) AllocateBaseID() uint64 {
	id := s.NextBaseID
	s.NextBaseID++
	return id
}

func (s *SessionState) AllocateTemplateID() uint64 {
	id := s.NextTemplateID
	s.NextTemplateID++
	return id
}

func (s *SessionState) AllocateDictionaryID() uint64 {
	id := s.NextDictionaryID
	s.NextDictionaryID++
	return id
}

func (s *SessionState) GetBaseSnapshot(baseID uint64) (*Message, bool) {
	for i := range s.BaseSnapshots {
		if s.BaseSnapshots[i].ID == baseID {
			m := s.BaseSnapshots[i].Message.Clone()
			return &m, true
		}
	}
	return nil, false
}

func (s *SessionState) ResetTables() {
	s.KeyTable.Clear()
	s.StringTable.Clear()
	s.ShapeTable.Clear()
	s.EncodeShapeObservations = make(map[string]uint64)
	s.FieldEnums = make(map[string][]string)
}

func (s *SessionState) ResetState() {
	s.ResetTables()
	s.BaseSnapshots = nil
	s.Templates = make(map[uint64]TemplateDescriptor)
	s.TemplateColumns = make(map[uint64][]Column)
	s.Dictionaries = make(map[uint64][]byte)
	s.DictionaryProfiles = make(map[uint64]DictionaryProfile)
	s.Schemas = make(map[uint64]Schema)
	s.LastSchemaID = nil
	s.PreviousMessage = nil
	s.PreviousMessageSize = nil
	s.NextBaseID = 0
	s.NextTemplateID = 0
	s.NextDictionaryID = 0
}
