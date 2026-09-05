package core

import (
	"errors"
	"reflect"
)

func requireTwilicErrorKind(t testingT, err error, kind TwilicErrorKind) *TwilicError {
	t.Helper()
	var te *TwilicError
	if !errors.As(err, &te) {
		t.Fatalf("expected TwilicError, got %v", err)
	}
	if te.Kind != kind {
		t.Fatalf("expected error kind %v, got %v", kind, te.Kind)
	}
	return te
}

type testingT interface {
	Helper()
	Fatalf(format string, args ...any)
}

func EqualMessage(a, b Message) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case MessageKindScalar:
		return Equal(a.Scalar.Clone(), b.Scalar.Clone())
	case MessageKindArray:
		if len(a.Array) != len(b.Array) {
			return false
		}
		for i := range a.Array {
			if !Equal(a.Array[i], b.Array[i]) {
				return false
			}
		}
		return true
	case MessageKindMap:
		if len(a.Map) != len(b.Map) {
			return false
		}
		for i := range a.Map {
			if !equalKeyRef(a.Map[i].Key, b.Map[i].Key) || !Equal(a.Map[i].Value, b.Map[i].Value) {
				return false
			}
		}
		return true
	default:
		return reflect.DeepEqual(a.Clone(), b.Clone())
	}
}

func equalKeyRef(a, b KeyRef) bool {
	return a.IsID == b.IsID && a.ID == b.ID && a.Literal == b.Literal
}

func messageMapEntry(key string, value Value) MessageMapEntry {
	return MessageMapEntry{Key: KeyRefLiteral(key), Value: value}
}
