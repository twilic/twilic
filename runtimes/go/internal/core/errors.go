package core

import (
	"errors"
	"fmt"
)

type TwilicError struct {
	Kind TwilicErrorKind
	// InvalidKind / InvalidTag
	Byte byte
	// InvalidData
	Msg string
	// UnknownReference / StatelessRetryRequired
	RefKind string
	RefID   uint64
}

type TwilicErrorKind int

const (
	ErrUnexpectedEOF TwilicErrorKind = iota
	ErrInvalidKind
	ErrInvalidTag
	ErrInvalidData
	ErrUTF8
	ErrUnknownReference
	ErrStatelessRetryRequired
)

func (e *TwilicError) Error() string {
	switch e.Kind {
	case ErrUnexpectedEOF:
		return "unexpected end of input"
	case ErrInvalidKind:
		return fmt.Sprintf("invalid message kind: %#04x", e.Byte)
	case ErrInvalidTag:
		return fmt.Sprintf("invalid value tag: %#04x", e.Byte)
	case ErrInvalidData:
		return fmt.Sprintf("invalid data: %s", e.Msg)
	case ErrUTF8:
		return "utf8 decode error"
	case ErrUnknownReference:
		return fmt.Sprintf("unknown reference: %s=%d", e.RefKind, e.RefID)
	case ErrStatelessRetryRequired:
		return fmt.Sprintf("stateless retry required for reference: %s=%d", e.RefKind, e.RefID)
	default:
		return "twilic error"
	}
}

func unexpectedEOF() error {
	return &TwilicError{Kind: ErrUnexpectedEOF}
}

func invalidKind(b byte) error {
	return &TwilicError{Kind: ErrInvalidKind, Byte: b}
}

func invalidTag(b byte) error {
	return &TwilicError{Kind: ErrInvalidTag, Byte: b}
}

func invalidData(msg string) error {
	return &TwilicError{Kind: ErrInvalidData, Msg: msg}
}

func utf8Error() error {
	return &TwilicError{Kind: ErrUTF8}
}

func unknownReference(kind string, id uint64) error {
	return &TwilicError{Kind: ErrUnknownReference, RefKind: kind, RefID: id}
}

func statelessRetryRequired(kind string, id uint64) error {
	return &TwilicError{Kind: ErrStatelessRetryRequired, RefKind: kind, RefID: id}
}

func isStatelessRetry(err error) bool {
	var te *TwilicError
	return errors.As(err, &te) && te.Kind == ErrStatelessRetryRequired
}

func isUnknownReference(err error) bool {
	var te *TwilicError
	return errors.As(err, &te) && te.Kind == ErrUnknownReference
}
