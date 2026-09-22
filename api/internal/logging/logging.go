// Package logging writes structured lines that cannot carry a resident.
//
// phi-safe-logging.sql keeps a view called never_log: every column classified phi,
// identifying or secret, minus the identifiers a log line exists to carry. It is computed
// from the classification rather than maintained by hand, so a column added to the model
// next month is on it without anybody remembering.
//
// This package is the application half of that. A log line is a set of named fields, the
// names are checked against a list built from never_log, and a forbidden one is dropped
// with the field name kept - so the line still says a name was there and refused, rather
// than quietly becoming a different line.
//
// Values are never inspected. A checker that looked for things that resemble a name would
// be wrong about "Meadow" and "Reed" and right about nothing, and it would make the rule
// about the value rather than about the field, which is where it belongs.
package logging

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"sync"
	"time"
)

type Logger struct {
	mu        sync.Mutex
	out       io.Writer
	forbidden map[string]struct{}
}

// New takes the field names that must never appear. Loading them is the caller's job -
// api/main.go reads never_log at start-up - so this package holds no copy of a list that
// lives in the database.
func New(out io.Writer, neverLog []string) *Logger {
	f := make(map[string]struct{}, len(neverLog))
	for _, name := range neverLog {
		f[name] = struct{}{}
	}
	return &Logger{out: out, forbidden: f}
}

// Fields refused so far, for a start-up line and for the tests.
func (l *Logger) Forbidden() []string {
	out := make([]string, 0, len(l.forbidden))
	for k := range l.forbidden {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

type Field struct {
	Key   string
	Value any
}

func F(key string, value any) Field { return Field{key, value} }

func (l *Logger) Info(msg string, fields ...Field)  { l.write("info", msg, fields) }
func (l *Logger) Error(msg string, fields ...Field) { l.write("error", msg, fields) }

func (l *Logger) write(level, msg string, fields []Field) {
	line := map[string]any{
		"time":  time.Now().UTC().Format(time.RFC3339),
		"level": level,
		"msg":   msg,
	}
	for _, f := range fields {
		if _, no := l.forbidden[f.Key]; no {
			// The name stays, the value does not. A dropped field that disappeared
			// entirely would leave a log line that reads as though nothing was there.
			line[f.Key] = "[redacted: never_log]"
			continue
		}
		line[f.Key] = f.Value
	}
	b, err := json.Marshal(line)
	if err != nil {
		b = []byte(fmt.Sprintf(`{"level":"error","msg":"a log line would not marshal: %v"}`, err))
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.out.Write(append(b, '\n'))
}
