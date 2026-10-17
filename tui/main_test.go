// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// testConfigDir is the empty user config directory every test runs with.
var testConfigDir string

// TestMain points the user config directory at an empty temporary one, so
// initialModel starts from the default settings whatever the developer saved
// in the TUI, and no test reads or writes the real settings.json.
// os.UserConfigDir reads XDG_CONFIG_HOME or HOME on Linux, HOME on macOS and
// AppData on Windows.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "libmpv-tui-test-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	testConfigDir = dir
	for _, k := range []string{"XDG_CONFIG_HOME", "HOME", "AppData"} {
		os.Setenv(k, dir)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// TestSettingsPathIsTheTestOne guards TestMain: the settings file the tests
// see lives in the temporary config directory.
func TestSettingsPathIsTheTestOne(t *testing.T) {
	p, err := settingsPath()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(p, testConfigDir) {
		t.Fatalf("settings path %q is outside the test config dir %q", p, testConfigDir)
	}
}
