package main

import (
	"strconv"
	"strings"
	"sync"

	"golang.org/x/sys/windows"
)

type diagnosticSocketPattern struct {
	code uint32
	text string
}

var diagnosticSocketPatternOnce sync.Once
var diagnosticSocketPatterns []diagnosticSocketPattern
var diagnosticSocketFallbacks [len(diagnosticSocketCodes)]string

func loadDiagnosticSocketPatterns() {
	// Nine fixed codes times three languages: at most 27 FormatMessage calls,
	// once per helper process, never once per log line. No sockets are opened.
	for index, code := range diagnosticSocketCodes {
		diagnosticSocketFallbacks[index] = "winapi error #" + strconv.FormatUint(uint64(code), 10)
		for _, language := range []uint32{0, 0x0409, 0x0419} {
			buffer := make([]uint16, 2048)
			n, err := windows.FormatMessage(windows.FORMAT_MESSAGE_FROM_SYSTEM|windows.FORMAT_MESSAGE_IGNORE_INSERTS,
				0, code, language, buffer, nil)
			if err != nil || n == 0 {
				continue
			}
			text := strings.ToLower(strings.Join(strings.Fields(windows.UTF16ToString(buffer[:n])), " "))
			if len(text) < 12 {
				continue
			}
			duplicate := false
			for _, pattern := range diagnosticSocketPatterns {
				if pattern.code == code && pattern.text == text {
					duplicate = true
					break
				}
			}
			if !duplicate {
				diagnosticSocketPatterns = append(diagnosticSocketPatterns, diagnosticSocketPattern{code, text})
			}
		}
	}
}

func diagnosticSocketCode(line string) uint32 {
	diagnosticSocketPatternOnce.Do(loadDiagnosticSocketPatterns)
	for _, pattern := range diagnosticSocketPatterns {
		if strings.Contains(line, pattern.text) {
			return pattern.code
		}
	}
	// Go's documented fallback when FormatMessage fails. A bare port, address,
	// arbitrary number or remote close reason is not accepted as a socket code.
	for index, code := range diagnosticSocketCodes {
		text := diagnosticSocketFallbacks[index]
		if index := strings.Index(line, text); index >= 0 {
			end := index + len(text)
			if end == len(line) || line[end] < '0' || line[end] > '9' {
				return code
			}
		}
	}
	return 0
}
