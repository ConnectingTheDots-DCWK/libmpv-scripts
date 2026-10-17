// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"os"
	"regexp"
	"testing"
)

// TestVersionMatchesChangelog keeps the version in the header equal to the
// newest release in CHANGELOG.md, so a release that adds its heading there
// also bumps version.go.
func TestVersionMatchesChangelog(t *testing.T) {
	data, err := os.ReadFile("../CHANGELOG.md")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^## \[([0-9]+\.[0-9]+\.[0-9]+)\]`).FindSubmatch(data)
	if m == nil {
		t.Fatal("no release heading in CHANGELOG.md")
	}
	if got := string(m[1]); got != version {
		t.Errorf("version.go says %s, the newest CHANGELOG release is %s", version, got)
	}
}
