package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestToolDefinitionCount(t *testing.T) {
	if got := len(toolDefinitions()); got != 10 {
		t.Fatalf("toolDefinitions() count = %d, want 10", got)
	}
}

func TestClickMethodSchemaAndParser(t *testing.T) {
	tool := findToolDefinition(t, "click")
	if !strings.Contains(tool.Description, "Element-targeted coordinate fallback requires a valid snapshot frame or explicit finite x/y") {
		t.Fatal("click description must document the missing-frame coordinate boundary")
	}
	properties := tool.InputSchema["properties"].(map[string]any)
	method := properties["click_method"].(map[string]any)
	values := method["enum"].([]string)
	if strings.Join(values, ",") != "auto,accessibility,app_post,sky_click,global" {
		t.Fatalf("click_method enum = %#v", values)
	}
	description := method["description"].(string)
	if !strings.Contains(description, "global requires explicit foreground and global-pointer environment authorization") {
		t.Fatalf("click_method description = %q", description)
	}

	for input, want := range map[string]string{
		"":              "auto",
		" AUTO ":        "auto",
		"Accessibility": "accessibility",
		"app_post":      "app_post",
		"SKY_CLICK":     "sky_click",
		"GLOBAL":        "global",
	} {
		got, err := parseClickMethod(input)
		if err != nil {
			t.Fatalf("parseClickMethod(%q): %v", input, err)
		}
		if got != want {
			t.Fatalf("parseClickMethod(%q) = %q, want %q", input, got, want)
		}
	}

	for _, input := range []string{"physical", "targeted"} {
		if _, err := parseClickMethod(input); err == nil || !strings.Contains(err.Error(), "Expected one of: auto, accessibility, app_post, sky_click, global") {
			t.Fatalf("parseClickMethod(%s) error = %v", input, err)
		}
	}
}

func TestClickEnumArgumentsRejectNonStringsAndUnknownValues(t *testing.T) {
	for _, args := range []map[string]any{
		{"app": "Fixture", "click_method": 1},
		{"app": "Fixture", "click_method": "not-a-method"},
		{"app": "Fixture", "mouse_button": 1},
		{"app": "Fixture", "mouse_button": "not-a-button"},
	} {
		result := newService().callTool("click", args)
		if !result.IsError || len(result.Content) == 0 || result.Content[0].Text == "" {
			t.Fatalf("invalid click enum args %#v produced %#v", args, result)
		}
		if strings.Contains(result.Content[0].Text, "Target changed") {
			t.Fatalf("invalid click enum args %#v were misclassified as target change: %#v", args, result)
		}
	}
	if got, err := parseMouseButton(""); err != nil || got != "left" {
		t.Fatalf("empty mouse button = (%q, %v), want left", got, err)
	}
	if got, err := parseMouseButton(" RIGHT "); err != nil || got != "right" {
		t.Fatalf("normalized mouse button = (%q, %v), want right", got, err)
	}
}

func TestElementReferenceProtocolIsGenerationBound(t *testing.T) {
	for _, value := range []string{"s-0000000000000001:0", "s-ffffffffffffffff:42"} {
		if prefix, index, ok := parseElementReference(value); !ok || prefix == "" || index < 0 {
			t.Fatalf("parseElementReference(%q) = (%q, %d, %v), want valid reference", value, prefix, index, ok)
		}
	}
	for _, value := range []string{"15", "s-1:15", "s-0000000000000000:15", "s-0000000000000001:-1", "s-0000000000000001:bad"} {
		if _, _, ok := parseElementReference(value); ok {
			t.Fatalf("parseElementReference(%q) accepted malformed/legacy reference", value)
		}
	}
	click := findToolDefinition(t, "click")
	clickDescription := click.InputSchema["properties"].(map[string]any)["element_index"].(map[string]any)["description"].(string)
	if !strings.Contains(clickDescription, "Generation-bound element identifier") {
		t.Fatalf("click element identifier description = %q", clickDescription)
	}
	if !strings.Contains(click.Description, "Legacy numeric element indices are rejected") {
		t.Fatalf("click description does not document legacy rejection: %q", click.Description)
	}
	if !strings.Contains(serverInstructions, "generation-bound element identifier") || !strings.Contains(serverInstructions, "complete identifier as opaque") {
		t.Fatalf("server instructions do not document snapshot-bound identifiers")
	}
}

func TestElementReferenceAndIntegerBoundsAreStrict(t *testing.T) {
	for _, value := range []string{
		"s-0000000000000001:+1",
		"s-0000000000000001:01",
		"s-0000000000000001:" + strings.Repeat("9", maxElementIndexDigits+1),
		"s-0000000000000001:1:2",
	} {
		if _, _, ok := parseElementReference(value); ok {
			t.Fatalf("oversized/noncanonical element reference %q was accepted", value)
		}
	}
	if _, err := positiveIntFromValue(json.Number("9007199254740992"), "limit"); err == nil {
		t.Fatal("integer beyond exact JSON-safe range was accepted")
	}
}

func TestWindowsGlobalClickRequiresSnapshotBeforeRuntime(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click("Notepad", "", &x, &y, 1, "left", "global")
	if !result.IsError || result.Content[0].Text != "No app state is available. Run get_app_state before action tools." {
		t.Fatalf("global click result = %#v", result)
	}
}

func TestWindowsTypeTextRequiresSnapshotBeforeRuntime(t *testing.T) {
	result := newService().typeText("Notepad", "hello")
	if !result.IsError || result.Content[0].Text != "No app state is available. Run get_app_state before action tools." {
		t.Fatalf("type_text result = %#v", result)
	}
}

func TestSnapshotIdentityIsMarshaledIntoActionRequests(t *testing.T) {
	snapshot := &appSnapshot{
		App: appDescriptor{
			PID:                   1234,
			ProcessStartTimeTicks: 987654321,
			MainWindowHandle:      4321,
		},
		WindowBounds: &frame{X: 10, Y: 20, Width: 300, Height: 200},
	}
	request, err := bindSnapshotTarget(snapshot, psRequest{Tool: "drag", App: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	for _, marker := range []string{
		`"expectedPid":1234`,
		`"expectedProcessStartTimeTicks":987654321`,
		`"expectedMainWindowHandle":4321`,
		`"windowBounds":{"x":10,"y":20,"width":300,"height":200}`,
	} {
		if !strings.Contains(text, marker) {
			t.Fatalf("action request missing %s: %s", marker, text)
		}
	}
}

func TestSnapshotCacheRejectsAmbiguousProcessAliases(t *testing.T) {
	service := newService()
	first := &appSnapshot{App: appDescriptor{Name: "pwsh", BundleIdentifier: "pwsh", PID: 1001, ProcessStartTimeTicks: 10, MainWindowHandle: 101}, WindowTitle: "Fixture A"}
	second := &appSnapshot{App: appDescriptor{Name: "pwsh", BundleIdentifier: "pwsh", PID: 1002, ProcessStartTimeTicks: 20, MainWindowHandle: 202}, WindowTitle: "Fixture B"}
	firstPublished := service.rememberSnapshot("Fixture A", first)
	secondPublished := service.rememberSnapshot("Fixture B", second)

	if got := service.currentSnapshot("Fixture A"); got != firstPublished {
		t.Fatalf("exact title A snapshot = %#v, want first", got)
	}
	if got := service.currentSnapshot("Fixture B"); got != secondPublished {
		t.Fatalf("exact title B snapshot = %#v, want second", got)
	}
	if got := service.currentSnapshot("1001"); got != firstPublished {
		t.Fatalf("PID A snapshot = %#v, want first", got)
	}
	if got := service.currentSnapshot("pwsh"); got != nil {
		t.Fatalf("shared process alias must be ambiguous, got %#v", got)
	}
	result := service.snapshotActionError("pwsh")
	if !result.IsError || !strings.Contains(result.Content[0].Text, "matches multiple cached targets") {
		t.Fatalf("ambiguous alias error = %#v", result)
	}
}

func syntheticSnapshot(name string, pid int, startTimeTicks int64, hwnd int64, index int) *appSnapshot {
	return &appSnapshot{
		App: appDescriptor{
			Name:                  name,
			BundleIdentifier:      name,
			PID:                   pid,
			ProcessStartTimeTicks: startTimeTicks,
			MainWindowHandle:      hwnd,
		},
		WindowTitle: name,
		TreeLines:   []string{"\t" + strconv.Itoa(index) + " Edit target"},
		Elements: []elementRecord{{
			Index:       index,
			Name:        "target",
			ControlType: "ControlType.Edit",
		}},
	}
}

func TestSnapshotElementReferenceExpiresOnRefresh(t *testing.T) {
	service := newService()
	first := service.rememberSnapshot("Fixture", syntheticSnapshot("fixture", 1001, 10, 101, 15))
	oldReference := first.Elements[0].publicRef
	if oldReference == "" || !strings.HasPrefix(oldReference, "s-") {
		t.Fatalf("first snapshot reference = %q, want generation-qualified reference", oldReference)
	}
	renderedLines := first.renderedTreeLines()
	if len(renderedLines) != 1 || renderedLines[0] != "\t"+oldReference+" Edit target" {
		t.Fatalf("rendered snapshot lines = %#v, want tokenized tree line", renderedLines)
	}

	second := service.rememberSnapshot("Fixture", syntheticSnapshot("fixture", 1001, 10, 101, 15))
	newReference := second.Elements[0].publicRef
	if newReference == "" || newReference == oldReference {
		t.Fatalf("second snapshot reference = %q, old = %q", newReference, oldReference)
	}
	if service.isCurrentSnapshot(first) {
		t.Fatal("superseded snapshot remained current")
	}
	if _, _, err := service.lookupElementForApp("Fixture", oldReference); err == nil || err.Error() != targetChangedMessage {
		t.Fatalf("old reference error = %v, want %q", err, targetChangedMessage)
	}
	current, record, err := service.lookupElementForApp("Fixture", newReference)
	if err != nil {
		t.Fatalf("fresh reference lookup failed: %v", err)
	}
	if current != second || record.publicRef != newReference {
		t.Fatalf("fresh reference resolved to snapshot=%p record=%+v, want snapshot=%p ref=%q", current, record, second, newReference)
	}
}

func TestLegacyElementIndexFailsClosedBeforeCoordinateFallback(t *testing.T) {
	service := newService()
	snapshot := syntheticSnapshot("fixture", 1001, 10, 101, 15)
	service.rememberSnapshot("Fixture", snapshot)
	values := []any{"15", json.Number("15"), float64(15), "", "s-invalid:15"}
	for _, value := range values {
		result := service.callTool("click", map[string]any{
			"app":           "Fixture",
			"element_index": value,
			"x":             10,
			"y":             10,
		})
		if !result.IsError || len(result.Content) == 0 || result.Content[0].Text != targetChangedMessage {
			t.Fatalf("legacy/malformed element_index %#v result = %#v, want bounded target change", value, result)
		}
	}
}

func TestAllIndexedActionsRejectSupersededReferenceBeforeDelivery(t *testing.T) {
	service := newService()
	first := service.rememberSnapshot("Fixture", syntheticSnapshot("fixture", 1001, 10, 101, 15))
	oldReference := first.Elements[0].publicRef
	service.rememberSnapshot("Fixture", syntheticSnapshot("fixture", 1001, 10, 101, 15))

	cases := []struct {
		name string
		args map[string]any
	}{
		{name: "click", args: map[string]any{"app": "Fixture", "element_index": oldReference}},
		{name: "secondary", args: map[string]any{"app": "Fixture", "element_index": oldReference, "action": "Invoke"}},
		{name: "scroll", args: map[string]any{"app": "Fixture", "element_index": oldReference, "direction": "down"}},
		{name: "set_value", args: map[string]any{"app": "Fixture", "element_index": oldReference, "value": "blocked"}},
	}
	tools := map[string]string{"click": "click", "secondary": "perform_secondary_action", "scroll": "scroll", "set_value": "set_value"}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			result := service.callTool(tools[testCase.name], testCase.args)
			if !result.IsError || len(result.Content) == 0 || result.Content[0].Text != targetChangedMessage {
				t.Fatalf("superseded %s result = %#v, want bounded target change", testCase.name, result)
			}
		})
	}
}
func TestSnapshotAliasRefreshUpdatesOlderQueryAlias(t *testing.T) {
	service := newService()
	first := syntheticSnapshot("fixture", 1001, 10, 101, 15)
	first.WindowTitle = "Fixture Window"
	firstPublished := service.rememberSnapshot("fixture", first)
	if got := service.currentSnapshot("Fixture Window"); got != firstPublished {
		t.Fatalf("snapshot title alias resolved to %p, want %p", got, firstPublished)
	}
	second := syntheticSnapshot("fixture", 1001, 10, 101, 15)
	second.WindowTitle = "Fixture Window"
	secondPublished := service.rememberSnapshot("1001", second)
	if got := service.currentSnapshot("Fixture Window"); got != secondPublished {
		t.Fatalf("older query alias resolved to %p, want latest snapshot %p", got, secondPublished)
	}
	if _, _, err := service.lookupElementForApp("Fixture Window", secondPublished.Elements[0].publicRef); err != nil {
		t.Fatalf("fresh token through older query alias failed: %v", err)
	}
}

func TestSnapshotAliasKeyRetentionIsBounded(t *testing.T) {
	service := newService()
	for index := 0; index < maxAliasKeys+20; index++ {
		name := "unique-query-" + strconv.Itoa(index)
		service.rememberSnapshot(name, syntheticSnapshot(name, 6000+index, int64(100+index), int64(7000+index), 1))
	}
	if len(service.aliases) > maxAliasKeys {
		t.Fatalf("alias key count = %d, want <= %d", len(service.aliases), maxAliasKeys)
	}
}

func TestSnapshotAliasExpiryDoesNotPermanentlyPoisonSelector(t *testing.T) {
	service := newService()
	now := time.Unix(1000, 0)
	service.now = func() time.Time { return now }
	service.rememberSnapshot("shared", syntheticSnapshot("shared", 1001, 10, 101, 1))
	now = now.Add(snapshotAliasTTL + time.Second)
	second := service.rememberSnapshot("shared", syntheticSnapshot("shared", 1002, 20, 202, 1))
	if got := service.currentSnapshot("shared"); got != second {
		t.Fatalf("expired alias resolved to %p, want second snapshot %p", got, second)
	}
	if service.snapshotIsAmbiguous("shared") {
		t.Fatal("expired alias remained ambiguous")
	}
}

func TestInactiveAliasExpiresWhileAnotherAliasRefreshes(t *testing.T) {
	service := newService()
	now := time.Unix(2000, 0)
	service.now = func() time.Time { return now }
	first := service.rememberSnapshot("old-selector", syntheticSnapshot("fixture", 1101, 11, 111, 1))
	if first == nil || service.currentSnapshot("old-selector") != first {
		t.Fatal("old selector did not publish its initial snapshot")
	}
	now = now.Add(snapshotAliasTTL / 2)
	second := service.rememberSnapshot("hot-selector", syntheticSnapshot("fixture", 1101, 11, 111, 1))
	if second == nil || service.currentSnapshot("hot-selector") != second {
		t.Fatal("hot selector did not publish its refreshed snapshot")
	}
	now = now.Add(snapshotAliasTTL/2 + time.Second)
	third := service.rememberSnapshot("hot-selector", syntheticSnapshot("fixture", 1101, 11, 111, 1))
	if third == nil || service.currentSnapshot("hot-selector") != third {
		t.Fatal("hot selector was incorrectly expired")
	}
	if got := service.currentSnapshot("old-selector"); got != nil {
		t.Fatalf("inactive old selector remained alive after TTL: %#v", got)
	}
}

func TestPublishedSnapshotsAreDetachedFromRuntimeResponses(t *testing.T) {
	service := newService()
	source := syntheticSnapshot("fixture", 1001, 10, 101, 15)
	source.ScreenshotPNGBase64 = "png"
	source.WindowBounds = &frame{X: 1, Y: 2, Width: 300, Height: 200}
	source.Elements[0].RuntimeID = []int{7, 8}
	source.Elements[0].Actions = []string{"Invoke"}
	source.Elements[0].Frame = &frame{X: 3, Y: 4, Width: 10, Height: 11}
	published := service.rememberSnapshot("Fixture", source)
	if published == nil || published == source {
		t.Fatal("snapshot publication must detach the cached snapshot from the runtime response")
	}
	if source.snapshotToken != "" || source.Elements[0].publicRef != "" {
		t.Fatal("publication must not mutate the runtime-owned snapshot")
	}

	source.TreeLines[0] = "mutated"
	source.ScreenshotPNGBase64 = "changed"
	source.WindowBounds.X = 99
	source.Elements[0].RuntimeID[0] = 99
	source.Elements[0].Actions[0] = "changed"
	source.Elements[0].Frame.Width = 999
	cached := service.currentSnapshot("Fixture")
	if cached != published || cached.TreeLines[0] == "mutated" || cached.ScreenshotPNGBase64 != "png" || cached.WindowBounds.X != 1 || cached.Elements[0].RuntimeID[0] != 7 || cached.Elements[0].Actions[0] != "Invoke" || cached.Elements[0].Frame.Width != 10 {
		t.Fatalf("cached snapshot was affected by source mutation: %#v", cached)
	}
}

func TestInvalidSnapshotRecordsAreNotPublished(t *testing.T) {
	service := newService()
	original := service.rememberSnapshot("Fixture", syntheticSnapshot("fixture", 1001, 10, 101, 1))
	if original == nil {
		t.Fatal("baseline snapshot was not published")
	}
	invalid := syntheticSnapshot("fixture", 1001, 10, 101, 2)
	invalid.Elements = append(invalid.Elements, cloneElementRecord(invalid.Elements[0]))
	if published := service.rememberSnapshot("Fixture", invalid); published != nil {
		t.Fatal("duplicate-index snapshot was published")
	}
	if got := service.currentSnapshot("Fixture"); got != original {
		t.Fatal("invalid snapshot replaced the valid cached snapshot")
	}
	negative := syntheticSnapshot("fixture", 1001, 10, 101, 2)
	negative.Elements[0].Index = -1
	if published := service.rememberSnapshot("Fixture", negative); published != nil {
		t.Fatal("negative-index snapshot was published")
	}
	if got := service.currentSnapshot("Fixture"); got != original {
		t.Fatal("negative-index snapshot poisoned the cache")
	}
}

func TestSnapshotTokenBindingsAreBounded(t *testing.T) {
	service := newService()
	first := service.rememberSnapshot("fixture-0", syntheticSnapshot("fixture-0", 2000, 20, 3000, 1))
	oldReference := first.Elements[0].publicRef
	for index := 1; index <= maxSnapshotBindings+4; index++ {
		name := "fixture-" + strconv.Itoa(index)
		service.rememberSnapshot(name, syntheticSnapshot(name, 2000+index, int64(20+index), int64(3000+index), 1))
	}
	if len(service.tokenBindings) > maxSnapshotBindings {
		t.Fatalf("token binding count = %d, want <= %d", len(service.tokenBindings), maxSnapshotBindings)
	}
	if _, _, err := service.lookupElementForApp("fixture-0", oldReference); err == nil || err.Error() != targetChangedMessage {
		t.Fatalf("evicted token error = %v, want %q", err, targetChangedMessage)
	}
}

func TestEvictedTargetCanBeRepopulatedWithoutAliasPoisoning(t *testing.T) {
	service := newService()
	first := service.rememberSnapshot("reusable", syntheticSnapshot("reusable", 3000, 30, 4000, 1))
	oldReference := first.Elements[0].publicRef
	for index := 0; index < maxSnapshotBindings+2; index++ {
		name := "other-" + strconv.Itoa(index)
		service.rememberSnapshot(name, syntheticSnapshot(name, 5000+index, int64(50+index), int64(6000+index), 1))
	}
	if _, _, err := service.lookupElementForApp("reusable", oldReference); err == nil || err.Error() != targetChangedMessage {
		t.Fatalf("evicted reusable token error = %v, want %q", err, targetChangedMessage)
	}
	fresh := service.rememberSnapshot("reusable", syntheticSnapshot("reusable", 3000, 30, 4000, 1))
	if fresh == nil || fresh.Elements[0].publicRef == oldReference {
		t.Fatal("repopulated target did not receive a fresh token")
	}
	if got := service.currentSnapshot("reusable"); got != fresh {
		t.Fatalf("repopulated selector resolved to %p, want %p", got, fresh)
	}
	if _, _, err := service.lookupElementForApp("reusable", fresh.Elements[0].publicRef); err != nil {
		t.Fatalf("fresh repopulated token lookup failed: %v", err)
	}
}

func TestSnapshotCacheConcurrentAccess(t *testing.T) {
	service := newService()
	var waitGroup sync.WaitGroup
	for index := 0; index < 128; index++ {
		waitGroup.Add(1)
		go func(index int) {
			defer waitGroup.Done()
			name := "concurrent-" + strconv.Itoa(index)
			snapshot := syntheticSnapshot(name, 4000+index, int64(100+index), int64(5000+index), index)
			service.rememberSnapshot(name, snapshot)
			_ = service.currentSnapshot(name)
			_ = service.snapshotIsAmbiguous(name)
		}(index)
	}
	waitGroup.Wait()
	if len(service.tokenBindings) > maxSnapshotBindings {
		t.Fatalf("concurrent token binding count = %d, want <= %d", len(service.tokenBindings), maxSnapshotBindings)
	}
}

func TestSnapshotIdentityRejectsIncompleteSnapshot(t *testing.T) {
	for _, snapshot := range []*appSnapshot{
		{},
		{App: appDescriptor{PID: 1234}},
		{App: appDescriptor{PID: 1234, ProcessStartTimeTicks: 1}},
	} {
		if _, err := bindSnapshotTarget(snapshot, psRequest{Tool: "click"}); err == nil {
			t.Fatalf("incomplete snapshot %#v was accepted", snapshot)
		}
	}
}

func TestWindowsRuntimeBindsActionsToSnapshotIdentity(t *testing.T) {
	for _, marker := range []string{
		"function Resolve-SnapshotActionTarget($operation)",
		"Get-Process -Id $expectedPid",
		"Get-ProcessStartTimeTicks $process",
		"$hwnd.ToInt64() -ne $expectedMainWindowHandle",
		"Target changed; call get_app_state again.",
		"Build-SnapshotForProcess $process $operation.app",
		"$escapedQuery = [System.Management.Automation.WildcardPattern]::Escape($normalized)",
		"$PSItem.MainWindowTitle -ilike \"*$escapedQuery*\"",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("snapshot identity contract missing %q", marker)
		}
	}
	if strings.Contains(windowsRuntimeScript, "$process = Resolve-App $operation.app") {
		t.Fatal("actions must not re-resolve the mutable app query")
	}
}
func TestWindowsRuntimeUsesSharedInteractiveTargetProof(t *testing.T) {
	for _, marker := range []string{
		"function Test-FrameIntersects($candidate, $desktop)",
		"function Test-FramesMatch($left, $right, [double]$tolerance = 1)",
		"function Test-UsableTopLevelWindow($process, $element, [IntPtr]$hwnd)",
		"function Resolve-InteractiveWindowTarget($process)",
		"GetSystemMetrics($SM_XVIRTUALSCREEN)",
		"GetAncestor($hwnd, 2)",
		"(Get-NativeWindowHandle $element) -ne $hwnd",
		"if ($usable.Count -ne 1)",
		"No usable top-level interactive window is available for the requested app.",
		"Resolve-InteractiveWindowTarget $process",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("shared interactive target proof missing %q", marker)
		}
	}
}

func TestWindowsRuntimeRequiresExactValidElementIdentity(t *testing.T) {
	for _, marker := range []string{
		"function Test-IntegerRuntimeIdValue($value)",
		"$isNumeric = $value -is [System.SByte]",
		"$number -eq [decimal]::Truncate($number)",
		"$number -ge [decimal][int32]::MinValue",
		"$number -le [decimal][int32]::MaxValue",
		"function Test-NonEmptyRuntimeId($runtimeId)",
		"if ($values.Count -eq 0)",
		"foreach ($value in $values)",
		"if (-not (Test-IntegerRuntimeIdValue $value))",
		"return $true",
		"function Same-RuntimeId($left, $right)",
		"if (-not (Test-NonEmptyRuntimeId $left) -or -not (Test-NonEmptyRuntimeId $right))",
		"[int64]$leftValues[$i] -ne [int64]$rightValues[$i]",
		"function Find-Element([IntPtr]$rootHwnd, $record)",
		"[Windows.Automation.AutomationElement]::FromHandle($rootHwnd)",
		"function Resolve-SnapshotElement([IntPtr]$rootHwnd, $record)",
		"if (-not (Test-NonEmptyRuntimeId $record.runtimeId))",
		"$element = Find-Element $rootHwnd $record",
		"if ($null -eq $element) {",
		"$element = Resolve-SnapshotElement $hwnd $operation.element",
		"function Get-BoundedRuntimeError($exception)",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows element identity contract missing %q", marker)
		}
	}
	if strings.Contains(windowsRuntimeScript, "$sameAutomationId") ||
		strings.Contains(windowsRuntimeScript, "$sameName") ||
		strings.Contains(windowsRuntimeScript, "$sameType") {
		t.Fatal("Windows element resolution must not use presentation metadata fallback")
	}
	if strings.Contains(windowsRuntimeScript, "$element = Find-Element $process $operation.element") {
		t.Fatal("element actions must pass through the shared snapshot element resolver")
	}
	if strings.Contains(windowsRuntimeScript, "$element = Resolve-SnapshotElement $process $operation.element") {
		t.Fatal("element actions must resolve from the snapshot-bound HWND, not a mutable process main window")
	}

	switchStart := strings.Index(windowsRuntimeScript, "        switch ($operation.tool) {")
	elementInitStart := strings.Index(windowsRuntimeScript, "        $element = $null")
	resolverStart := strings.Index(windowsRuntimeScript, "        $element = Resolve-SnapshotElement $hwnd $operation.element")
	if elementInitStart < 0 || resolverStart < 0 || switchStart < 0 || elementInitStart > resolverStart || resolverStart > switchStart {
		t.Fatal("snapshot element resolution must be initialized and conditional before action dispatch")
	}
	preDispatch := windowsRuntimeScript[elementInitStart:switchStart]
	if !strings.Contains(preDispatch, "if ($null -ne $operation.element) {") {
		t.Fatal("snapshot element resolution must be conditional so coordinate-only operations bypass the child-element gate")
	}
}

func TestWindowsRuntimeRejectsStaleElementsBeforeDelivery(t *testing.T) {
	resolverStart := strings.Index(windowsRuntimeScript, "function Resolve-SnapshotElement([IntPtr]$rootHwnd, $record)")
	dispatchStart := strings.Index(windowsRuntimeScript, "        $element = Resolve-SnapshotElement $hwnd $operation.element")
	if resolverStart < 0 || dispatchStart < 0 {
		t.Fatal("shared snapshot element resolver is missing")
	}
	resolverEnd := strings.Index(windowsRuntimeScript[resolverStart:], "function Get-CurrentPatternOrNull")
	if resolverEnd < 0 {
		t.Fatal("could not bound shared snapshot element resolver")
	}
	resolver := windowsRuntimeScript[resolverStart : resolverStart+resolverEnd]
	if strings.Contains(resolver, "Get-MainElement") {
		t.Fatal("snapshot element resolver must not re-root through a mutable process main window")
	}
	if strings.Contains(resolver, "Invoke-") || strings.Contains(resolver, "PostMessage") || strings.Contains(resolver, "SendInput") || strings.Contains(resolver, "Get-ScreenPoint") {
		t.Fatal("snapshot element resolver must not deliver input")
	}

	switchEndOffset := strings.Index(windowsRuntimeScript[dispatchStart:], "        Start-Sleep -Milliseconds 120")
	if switchEndOffset < 0 {
		t.Fatal("could not bound action dispatch")
	}
	dispatch := windowsRuntimeScript[dispatchStart : dispatchStart+switchEndOffset]
	for _, marker := range []string{
		"\"click\" {",
		"\"perform_secondary_action\" {",
		"\"scroll\" {",
		"\"set_value\" {",
		"Get-ValidatedScrollFallbackPoint $operation.element $windowBounds",
	} {
		if !strings.Contains(dispatch, marker) {
			t.Fatalf("element action dispatch missing %q", marker)
		}
	}
}

func TestWindowsRuntimeGuardsCoordinateAndAppScopedMessagePaths(t *testing.T) {
	for _, marker := range []string{
		"function Assert-SnapshotCoordinateBounds",
		"function Assert-AppScopedMessageTarget",
		"function Convert-ScreenPointToAppClient",
		"function Send-MouseClick($process",
		"function Send-Scroll($process",
		"function Test-HwndDescendantOf",
		"function Assert-ScreenPointInHwnd",
		"function Assert-AppPostDescendant",
		"Assert-AppPostDescendant $mainHwnd $elementHwnd $screenX $screenY",
		"Assert-ScreenPointInHwnd $hwnd $screenX $screenY",
		"if (-not [OCUWin32]::PostMessage",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("app-scoped safety contract missing %q", marker)
		}
	}
}

func TestWindowsScrollFallbackValidatesFrameBeforeDelivery(t *testing.T) {
	const helperStartMarker = "function Get-ValidatedScrollFallbackPoint($elementRecord, $windowBounds)"
	helperStart := strings.Index(windowsRuntimeScript, helperStartMarker)
	if helperStart < 0 {
		t.Fatal("scroll fallback frame-validation helper is missing")
	}
	helperEndOffset := strings.Index(windowsRuntimeScript[helperStart:], "function ConvertTo-AbsolutePointerPoint")
	if helperEndOffset < 0 {
		t.Fatal("could not bound scroll fallback frame-validation helper")
	}
	helper := windowsRuntimeScript[helperStart : helperStart+helperEndOffset]
	for _, marker := range []string{
		"Scroll requires an element with a valid frame when ScrollPattern is unavailable.",
		"if ($null -eq $elementRecord)",
		"Assert-ValidFrame $windowBounds $errorMessage $true",
		"Assert-ValidFrame $elementRecord.frame $errorMessage $true",
		"Get-ScreenPoint $elementRecord.frame $windowBounds",
	} {
		if !strings.Contains(helper, marker) {
			t.Fatalf("scroll fallback frame validation missing %q", marker)
		}
	}

	scrollStart := strings.Index(windowsRuntimeScript, `"scroll" {`)
	if scrollStart < 0 {
		t.Fatal("could not find scroll dispatch branch")
	}
	scrollEndOffset := strings.Index(windowsRuntimeScript[scrollStart:], `"drag" {`)
	if scrollEndOffset < 0 {
		t.Fatal("could not bound scroll dispatch branch")
	}
	scrollBranch := windowsRuntimeScript[scrollStart : scrollStart+scrollEndOffset]
	invokeOffset := strings.Index(scrollBranch, "Invoke-Scroll")
	boundsOffset := strings.Index(scrollBranch, "Assert-SnapshotCoordinateBounds $hwnd $windowBounds")
	pointOffset := strings.Index(scrollBranch, "Get-ValidatedScrollFallbackPoint $operation.element $windowBounds")
	sendOffset := strings.Index(scrollBranch, "Send-Scroll $process $hwnd $point.x $point.y")
	if invokeOffset < 0 || boundsOffset < 0 || pointOffset < 0 || sendOffset < 0 {
		t.Fatal("scroll dispatch is missing semantic, bounds, frame, or delivery stages")
	}
	if invokeOffset > pointOffset || boundsOffset > pointOffset || pointOffset > sendOffset {
		t.Fatal("scroll fallback validation is not ordered before coordinate/message delivery")
	}
	if strings.Contains(scrollBranch, "$operation.element.frame") {
		t.Fatal("scroll dispatch must not dereference the optional frame directly")
	}
}

func TestWindowsScrollUsesSinglePercentOperation(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$MaxScrollPages = 100.0") {
		t.Fatal("Windows runtime scroll bound must match the dispatcher bound")
	}
	pagesStart := strings.Index(windowsRuntimeScript, "function Get-OperationPages($operation)")
	if pagesStart < 0 {
		t.Fatal("scroll page helper is missing")
	}
	pagesEndOffset := strings.Index(windowsRuntimeScript[pagesStart:], "function Get-OperationClickCount")
	if pagesEndOffset < 0 {
		t.Fatal("could not bound scroll page helper")
	}
	pagesHelper := windowsRuntimeScript[pagesStart : pagesStart+pagesEndOffset]
	if !strings.Contains(pagesHelper, "return [double]$property.Value") {
		t.Fatal("PowerShell scroll path must preserve fractional pages")
	}

	scrollStart := strings.Index(windowsRuntimeScript, "function Get-ScrollPercentTarget")
	if scrollStart < 0 {
		t.Fatal("semantic scroll helper is missing")
	}
	scrollEndOffset := strings.Index(windowsRuntimeScript[scrollStart:], "# type_text has no element record")
	if scrollEndOffset < 0 {
		t.Fatal("could not bound semantic scroll helper")
	}
	scrollHelper := windowsRuntimeScript[scrollStart : scrollStart+scrollEndOffset]
	for _, marker := range []string{
		"function Get-ScrollPercentTarget",
		"HorizontalViewSize",
		"VerticalViewSize",
		"SetScrollPercent",
		"handled = $true; attempted = $true",
		"handled = $false; attempted = $true",
	} {
		if !strings.Contains(scrollHelper, marker) {
			t.Fatalf("semantic scroll helper missing %q", marker)
		}
	}
	if strings.Contains(scrollHelper, "for ($i = 0; $i -lt $repeat; $i++)") || strings.Contains(scrollHelper, "Start-Sleep -Milliseconds 40") {
		t.Fatal("semantic scroll must not perform a timeout-prone multi-mutation loop")
	}

	dispatchStart := strings.Index(windowsRuntimeScript, "            \"scroll\" {")
	if dispatchStart < 0 {
		t.Fatal("scroll dispatch branch is missing")
	}
	dispatchEndOffset := strings.Index(windowsRuntimeScript[dispatchStart:], "            \"drag\" {")
	if dispatchEndOffset < 0 {
		t.Fatal("could not bound scroll dispatch branch")
	}
	dispatch := windowsRuntimeScript[dispatchStart : dispatchStart+dispatchEndOffset]
	attemptOffset := strings.Index(dispatch, "$semanticResult = Invoke-Scroll")
	attemptErrorOffset := strings.Index(dispatch, "if (-not $handled -and $semanticResult.attempted)")
	fallbackOffset := strings.Index(dispatch, "if (-not $handled) {")
	if attemptOffset < 0 || attemptErrorOffset < 0 || fallbackOffset < 0 || attemptOffset > attemptErrorOffset || attemptErrorOffset > fallbackOffset {
		t.Fatal("scroll dispatch must reject attempted semantic failures before coordinate fallback")
	}
}

func TestWindowsScrollTimeoutRequiresRefresh(t *testing.T) {
	if got := runtimeTimeoutError(psRequest{Tool: "scroll"}).Error(); got != windowsScrollTimeoutMessage {
		t.Fatalf("scroll timeout error = %q, want %q", got, windowsScrollTimeoutMessage)
	}
	if got := runtimeTimeoutError(psRequest{Tool: "click"}).Error(); got != windowsRuntimeTimeoutMessage {
		t.Fatalf("generic timeout error = %q, want %q", got, windowsRuntimeTimeoutMessage)
	}
	if !strings.Contains(windowsScrollTimeoutMessage, "refresh with get_app_state") || !strings.Contains(windowsScrollTimeoutMessage, "may have been applied") {
		t.Fatalf("scroll timeout error lacks refresh/non-atomic guidance: %q", windowsScrollTimeoutMessage)
	}
}

func TestClickRequestPreservesOmittedAndExplicitZeroCoordinates(t *testing.T) {
	omitted, err := json.Marshal(psRequest{
		Tool:    "click",
		Element: &elementRecord{Index: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	var omittedPayload map[string]any
	if err := json.Unmarshal(omitted, &omittedPayload); err != nil {
		t.Fatal(err)
	}
	if _, ok := omittedPayload["x"]; ok {
		t.Fatalf("omitted x was serialized: %s", omitted)
	}
	if _, ok := omittedPayload["y"]; ok {
		t.Fatalf("omitted y was serialized: %s", omitted)
	}

	zero := 0.0
	explicit, err := json.Marshal(psRequest{
		Tool:    "click",
		Element: &elementRecord{Index: 1},
		X:       &zero,
		Y:       &zero,
	})
	if err != nil {
		t.Fatal(err)
	}
	var explicitPayload map[string]any
	if err := json.Unmarshal(explicit, &explicitPayload); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"x", "y"} {
		value, ok := explicitPayload[key]
		if !ok || value != float64(0) {
			t.Fatalf("explicit zero %s was not preserved: %s", key, explicit)
		}
	}
}

func TestWindowsClickFallbackValidatesPointSources(t *testing.T) {
	const helperStartMarker = "function Get-ValidatedClickPoint($elementRecord, $operation, $windowBounds)"
	helperStart := strings.Index(windowsRuntimeScript, helperStartMarker)
	if helperStart < 0 {
		t.Fatal("click point-validation helper is missing")
	}
	helperEndOffset := strings.Index(windowsRuntimeScript[helperStart:], "function Get-ValidatedScrollFallbackPoint")
	if helperEndOffset < 0 {
		t.Fatal("could not bound click point-validation helper")
	}
	helper := windowsRuntimeScript[helperStart : helperStart+helperEndOffset]
	for _, marker := range []string{
		"Click requires an element with a valid frame or explicit finite x/y coordinates.",
		"$null -eq $operation.x -or $null -eq $operation.y",
		"Assert-ValidFrame $windowBounds $errorMessage $true",
		"Assert-ValidFrame $frame $errorMessage $true",
		"Assert-FiniteCoordinate $operation.x \"x\"",
		"Assert-FiniteCoordinate $operation.y \"y\"",
		"Get-ScreenPoint $frame $windowBounds",
		"[double]$operation.x",
		"[double]$operation.y",
	} {
		if !strings.Contains(helper, marker) {
			t.Fatalf("click point validation missing %q", marker)
		}
	}

	const clickStartMarker = `"click" {`
	dispatchRoot := strings.Index(windowsRuntimeScript, "        switch ($operation.tool) {")
	if dispatchRoot < 0 {
		t.Fatal("could not find action dispatch root")
	}
	clickStart := strings.Index(windowsRuntimeScript[dispatchRoot:], clickStartMarker)
	if clickStart >= 0 {
		clickStart += dispatchRoot
	}
	if clickStart < 0 {
		t.Fatal("could not find click dispatch branch")
	}
	clickEndOffset := strings.Index(windowsRuntimeScript[clickStart:], `"perform_secondary_action" {`)
	if clickEndOffset < 0 {
		t.Fatal("could not bound click dispatch branch")
	}
	clickBranch := windowsRuntimeScript[clickStart : clickStart+clickEndOffset]
	const pointCall = "Get-ValidatedClickPoint $operation.element $operation $windowBounds"
	if strings.Count(clickBranch, pointCall) != 3 {
		t.Fatalf("click dispatch must use one guarded point path for app_post, global, and auto; count=%d", strings.Count(clickBranch, pointCall))
	}
	for _, forbidden := range []string{
		"$operation.element.frame",
		"[double]$operation.x",
		"[double]$operation.y",
	} {
		if strings.Contains(clickBranch, forbidden) {
			t.Fatalf("click dispatch retains an unguarded coordinate fallback %q", forbidden)
		}
	}

	assertBranchOrder := func(name, startMarker, endMarker, deliveryMarker string) {
		t.Helper()
		start := strings.Index(clickBranch, startMarker)
		if start < 0 {
			t.Fatalf("could not find %s click branch", name)
		}
		bodyStart := start + len(startMarker)
		endOffset := strings.Index(clickBranch[bodyStart:], endMarker)
		if endOffset < 0 {
			t.Fatalf("could not bound %s click branch", name)
		}
		branch := clickBranch[bodyStart : bodyStart+endOffset]
		boundsOffset := strings.Index(branch, "Assert-SnapshotCoordinateBounds $hwnd $windowBounds")
		pointOffset := strings.Index(branch, pointCall)
		deliveryOffset := strings.Index(branch, deliveryMarker)
		if boundsOffset < 0 || pointOffset < 0 || deliveryOffset < 0 || boundsOffset > pointOffset || pointOffset > deliveryOffset {
			t.Fatalf("%s click branch does not validate bounds, resolve the point, then deliver: %q", name, branch)
		}
	}
	assertBranchOrder("app_post", `} elseif ($clickMethod -eq "app_post") {`, `} elseif ($clickMethod -eq "global") {`, "Resolve-AppPostTargetHandle")
	assertBranchOrder("global", `} elseif ($clickMethod -eq "global") {`, `} elseif ($clickMethod -eq "sky_click") {`, "Send-InteractiveMouseClick")
	assertBranchOrder("auto", `} elseif ($clickMethod -eq "auto") {`, `throw "Invalid click_method '$clickMethod'"`, "Send-MouseClick")

	if !strings.Contains(windowsRuntimeScript, "function Get-BoundedRuntimeError($exception)") ||
		strings.Contains(windowsRuntimeScript, "$PSItem.ScriptStackTrace") {
		t.Fatal("click point errors must remain bounded at the PowerShell response boundary")
	}
}

func TestGetAppStateSchemaIncludesTextLimit(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	if _, ok := properties["show_full_text"]; ok {
		t.Fatal("get_app_state schema should not expose show_full_text")
	}
	textLimit := properties["text_limit"].(map[string]any)
	anyOf := textLimit["anyOf"].([]any)
	integerLimit := anyOf[0].(map[string]any)
	if got := integerLimit["type"]; got != "integer" {
		t.Fatalf("text_limit integer type = %v, want integer", got)
	}
	if got := integerLimit["minimum"]; got != 1 {
		t.Fatalf("text_limit integer minimum = %v, want 1", got)
	}
	maxLimit := anyOf[1].(map[string]any)
	if got := maxLimit["type"]; got != "string" {
		t.Fatalf("text_limit max type = %v, want string", got)
	}
	enum := maxLimit["enum"].([]string)
	if len(enum) != 1 || enum[0] != "max" {
		t.Fatalf("text_limit enum = %#v, want [max]", enum)
	}
	maxTreeNodes := properties["max_tree_nodes"].(map[string]any)
	if got := maxTreeNodes["type"]; got != "integer" {
		t.Fatalf("max_tree_nodes type = %v, want integer", got)
	}
	if got := maxTreeNodes["minimum"]; got != 1 {
		t.Fatalf("max_tree_nodes minimum = %v, want 1", got)
	}
	maxTreeDepth := properties["max_tree_depth"].(map[string]any)
	if got := maxTreeDepth["type"]; got != "integer" {
		t.Fatalf("max_tree_depth type = %v, want integer", got)
	}
	if got := maxTreeDepth["minimum"]; got != 1 {
		t.Fatalf("max_tree_depth minimum = %v, want 1", got)
	}
	required := tool.InputSchema["required"].([]string)
	if len(required) != 1 || required[0] != "app" {
		t.Fatalf("required = %#v, want [app]", required)
	}
}

func TestGetAppStateSchemaIncludesIncludeImage(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	includeImage := properties["include_image"].(map[string]any)
	if includeImage["type"] != "boolean" {
		t.Fatalf("include_image type = %v, want boolean", includeImage["type"])
	}
	if _, ok := properties["max_tree_depth"]; !ok {
		t.Fatal("get_app_state schema lost max_tree_depth")
	}
}

func TestModelVisionToolSelectionContract(t *testing.T) {
	for _, phrase := range []string{
		"`get_app_state` with `include_image=true`",
		"model-visible screenshot",
		"Do not use `press_key` to simulate PrintScreen, Win+Shift+S",
		"successful action already returns a refreshed screenshot",
		"`save_screenshot` only when the user asks to save or export a PNG file",
	} {
		if !strings.Contains(serverInstructions, phrase) {
			t.Fatalf("server instructions missing %q", phrase)
		}
	}

	state := findToolDefinition(t, "get_app_state")
	if !strings.Contains(state.Description, "model-visible screenshot") || !strings.Contains(state.Description, "screenshot shortcuts") {
		t.Fatalf("get_app_state description does not define visual inspection: %q", state.Description)
	}
	stateProperties := state.InputSchema["properties"].(map[string]any)
	includeImage := stateProperties["include_image"].(map[string]any)
	if !strings.Contains(includeImage["description"].(string), "model-visible screenshot") || !strings.Contains(includeImage["description"].(string), "press_key") {
		t.Fatalf("include_image description does not define the vision route: %q", includeImage["description"])
	}

	export := findToolDefinition(t, "save_screenshot")
	if !strings.Contains(export.Description, "only when the user asks to save or export") || !strings.Contains(export.Description, "get_app_state with include_image=true") {
		t.Fatalf("save_screenshot description does not distinguish export from model vision: %q", export.Description)
	}
}

func TestSaveScreenshotSchema(t *testing.T) {
	tool := findToolDefinition(t, "save_screenshot")
	properties := tool.InputSchema["properties"].(map[string]any)
	if properties["app"].(map[string]any)["type"] != "string" {
		t.Fatal("save_screenshot app must be a string")
	}
	if properties["path"].(map[string]any)["type"] != "string" {
		t.Fatal("save_screenshot path must be a string")
	}
	required := tool.InputSchema["required"].([]string)
	if strings.Join(required, ",") != "app,path" {
		t.Fatalf("save_screenshot required = %#v, want [app path]", required)
	}
}

func TestSaveScreenshotRejectsRelativePath(t *testing.T) {
	result := newService().saveScreenshot("msedge", "desktop.png")
	if !result.IsError || result.Content[0].Text != "save_screenshot path must be absolute" {
		t.Fatalf("relative save_screenshot result = %#v", result)
	}
}

func TestOptionalBool(t *testing.T) {
	if got, err := optionalBool(map[string]any{}, "include_image"); err != nil || got {
		t.Fatalf("missing bool = (%v, %v), want (false, nil)", got, err)
	}
	if got, err := optionalBool(map[string]any{"include_image": true}, "include_image"); err != nil || !got {
		t.Fatalf("true bool = (%v, %v), want (true, nil)", got, err)
	}
	if _, err := optionalBool(map[string]any{"include_image": "true"}, "include_image"); err == nil {
		t.Fatal("string bool should be rejected")
	}
}
func TestWindowsNumericArgumentValidation(t *testing.T) {
	for _, value := range []any{0, -1, 1.5, math.NaN(), math.Inf(1), json.Number("999999999999999999999999999999")} {
		if _, err := optionalClickCount(map[string]any{"click_count": value}, "click_count"); err == nil {
			t.Fatalf("click_count %#v was accepted", value)
		}
	}
	for _, value := range []any{1, 2.0, json.Number("2.0")} {
		got, err := optionalClickCount(map[string]any{"click_count": value}, "click_count")
		if err != nil || got < 1 || got > maxClickCount {
			t.Fatalf("click_count %#v = (%d, %v), want valid bounded integer", value, got, err)
		}
	}
	if got, err := optionalClickCount(map[string]any{}, "click_count"); err != nil || got != 1 {
		t.Fatalf("omitted click_count = (%d, %v), want default 1", got, err)
	}

	for _, value := range []any{0, -1, math.NaN(), math.Inf(1), maxScrollPages + 1, "2"} {
		if _, err := optionalScrollPages(map[string]any{"pages": value}, "pages"); err == nil {
			t.Fatalf("pages %#v was accepted", value)
		}
	}
	for _, test := range []struct {
		value any
		want  float64
	}{
		{value: 0.25, want: 0.25},
		{value: 1, want: 1},
		{value: json.Number("2.0"), want: 2},
		{value: float64(maxScrollPages), want: maxScrollPages},
	} {
		got, err := optionalScrollPages(map[string]any{"pages": test.value}, "pages")
		if err != nil || got != test.want {
			t.Fatalf("pages %#v = (%v, %v), want (%v, nil)", test.value, got, err, test.want)
		}
	}
	if got, err := optionalScrollPages(map[string]any{}, "pages"); err != nil || got != 1 {
		t.Fatalf("omitted pages = (%v, %v), want default 1", got, err)
	}

	for _, value := range []any{math.NaN(), math.Inf(1), maxCoordinateMagnitude + 1, "10", nil} {
		if _, err := coordinateFromValue(value, "x"); err == nil {
			t.Fatalf("coordinate %#v was accepted", value)
		}
	}
	for _, value := range []any{0, -10.5, maxCoordinateMagnitude} {
		if got, err := coordinateFromValue(value, "x"); err != nil || got != float64ValueForTest(value) {
			t.Fatalf("coordinate %#v = (%v, %v), want valid value", value, got, err)
		}
	}
}

func float64ValueForTest(value any) float64 {
	switch typed := value.(type) {
	case int:
		return float64(typed)
	case float64:
		return typed
	default:
		return 0
	}
}

func TestWindowsNumericSchemasExposeBounds(t *testing.T) {
	clickProperties := findToolDefinition(t, "click").InputSchema["properties"].(map[string]any)
	clickCount := clickProperties["click_count"].(map[string]any)
	if clickCount["minimum"] != 1 || clickCount["maximum"] != maxClickCount {
		t.Fatalf("click_count schema = %#v", clickCount)
	}
	for _, key := range []string{"x", "y"} {
		property := clickProperties[key].(map[string]any)
		if property["minimum"] != -maxCoordinateMagnitude || property["maximum"] != maxCoordinateMagnitude {
			t.Fatalf("click %s schema = %#v", key, property)
		}
	}
	scrollProperties := findToolDefinition(t, "scroll").InputSchema["properties"].(map[string]any)
	pages := scrollProperties["pages"].(map[string]any)
	if pages["exclusiveMinimum"] != 0 || pages["maximum"] != maxScrollPages {
		t.Fatalf("pages schema = %#v", pages)
	}
}

func TestParseSnapshotArgsSupportsTextLimit(t *testing.T) {
	app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs([]string{"--text-limit", "1000", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != 1000 || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs = (%q, %#v, %v, %v), want (Notepad, 1000, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad", "--text-limit", "max"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != "max" || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs max = (%q, %#v, %v, %v), want (Notepad, max, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs default = (%q, %#v, %v, %v), want (Notepad, nil, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"--max-tree-nodes", "3000", "--max-tree-depth", "96", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes == nil || *maxTreeNodes != 3000 || maxTreeDepth == nil || *maxTreeDepth != 96 {
		t.Fatalf("parseSnapshotArgs custom tree budget = (%q, %#v, %v, %v), want (Notepad, nil, 3000, 96)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}
}

func TestParseSnapshotArgsRejectsInvalidTextLimit(t *testing.T) {
	for _, value := range []string{"0", "-1", "1.5", "full"} {
		if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit", value, "Notepad"}); err == nil || err.Error() != "--text-limit must be a positive integer or max" {
			t.Fatalf("invalid text_limit %q error = %v", value, err)
		}
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit"}); err == nil || err.Error() != "--text-limit requires a positive integer or max value" {
		t.Fatalf("missing text_limit error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--show-full-text", "Notepad"}); err == nil || err.Error() != "unknown snapshot option: --show-full-text" {
		t.Fatalf("old show_full_text flag error = %v", err)
	}
}

func TestParseSnapshotArgsRejectsInvalidTreeBudget(t *testing.T) {
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes", "0", "Notepad"}); err == nil || err.Error() != "--max-tree-nodes must be a positive integer" {
		t.Fatalf("invalid max_tree_nodes error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-depth", "1.5", "Notepad"}); err == nil || err.Error() != "--max-tree-depth must be a positive integer" {
		t.Fatalf("invalid max_tree_depth error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes"}); err == nil || err.Error() != "--max-tree-nodes requires a positive integer value" {
		t.Fatalf("missing max_tree_nodes error = %v", err)
	}
}

func TestCallSequenceStopsAfterFirstToolError(t *testing.T) {
	output, hasError, err := runCallCommand([]string{
		"--calls",
		`[{"tool":"not_a_tool"},{"tool":"list_apps"}]`,
	}, newService())
	if err != nil {
		t.Fatal(err)
	}
	if !hasError {
		t.Fatal("expected hasError")
	}
	items, ok := output.([]map[string]any)
	if !ok {
		t.Fatalf("output type = %T", output)
	}
	if len(items) != 1 {
		t.Fatalf("sequence output count = %d, want 1", len(items))
	}
}

func TestReadArgumentsAcceptsJSONObject(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","pages":2}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if args["app"] != "Notepad" {
		t.Fatalf("app = %v", args["app"])
	}
	if args["pages"].(json.Number).String() != "2" {
		t.Fatalf("pages = %v", args["pages"])
	}
}

func TestStrictJSONInputRejectsTrailingData(t *testing.T) {
	if _, err := readArguments(`{"app":"Notepad"} trailing`, ""); err == nil || err.Error() != "Invalid JSON input." {
		t.Fatalf("trailing args error = %v, want bounded invalid JSON", err)
	}
	if _, err := readCallSequence(`[{"tool":"list_apps"}] {}`, ""); err == nil || err.Error() != "Invalid JSON input." {
		t.Fatalf("trailing calls error = %v, want bounded invalid JSON", err)
	}
	if _, err := readArguments(`{"app":"Notepad"}   `, ""); err != nil {
		t.Fatalf("trailing whitespace was rejected: %v", err)
	}
}

func TestCallSequenceRejectsMalformedShapes(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{name: "null", input: "null", want: "--calls must be a JSON array"},
		{name: "object", input: `{}`, want: "--calls must be a JSON array"},
		{name: "scalar item", input: `["list_apps"]`, want: "call sequence item #1 must be a JSON object"},
		{name: "bad args", input: `[{"tool":"list_apps","args":[]}]`, want: "call sequence item #1 args must be a JSON object"},
		{name: "both args", input: `[{"tool":"list_apps","args":{},"arguments":{}}]`, want: "call sequence item #1 cannot include both args and arguments"},
		{name: "bad tool", input: `[{"tool":1}]`, want: "call sequence item #1 tool must be a string"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := readCallSequence(testCase.input, ""); err == nil || err.Error() != testCase.want {
				t.Fatalf("error = %v, want %q", err, testCase.want)
			}
		})
	}
	calls, err := readCallSequence(`[{"name":"list_apps","arguments":{}}]`, "")
	if err != nil || len(calls) != 1 || calls[0].Tool != "list_apps" {
		t.Fatalf("valid name/arguments alias = %#v, %v", calls, err)
	}
}

func TestReadJSONSourceDoesNotExposeFilePath(t *testing.T) {
	path := `C:\private\missing\arguments.json`
	_, err := readJSONSource("", path)
	if err == nil || err.Error() != "Unable to read JSON input file." || strings.Contains(err.Error(), path) {
		t.Fatalf("file read error = %v, want bounded path-free error", err)
	}
}

func TestBoundedOutputCapsChildProcessDiagnostics(t *testing.T) {
	output := &boundedOutput{limit: 4}
	written, err := output.Write([]byte("abcdef"))
	if err != nil || written != 6 || string(output.Bytes()) != "abcd" {
		t.Fatalf("bounded output = written %d, err %v, bytes %q", written, err, output.Bytes())
	}
	if !output.Truncated() {
		t.Fatal("bounded output must report truncation")
	}
}

func TestBoundedRuntimeErrorsNeverExposeDiagnostics(t *testing.T) {
	if got := boundedRuntimeError("Target changed; call get_app_state again."); got != targetChangedMessage {
		t.Fatalf("target-change error = %q", got)
	}
	const unavailableMessage = "No usable top-level interactive window is available for the requested app."
	if got := boundedRuntimeError(unavailableMessage); got != unavailableMessage {
		t.Fatalf("unavailable target error = %q, want %q", got, unavailableMessage)
	}
	for _, message := range []string{
		"panic at C:\\temp\\runtime.ps1:42",
		"bad operation.json payload",
		"line one\nScriptStackTrace",
		strings.Repeat("x", 513),
	} {
		if got := boundedRuntimeError(message); got != "Windows runtime operation failed." {
			t.Fatalf("diagnostic %q was returned as %q", message, got)
		}
	}
	if got := boundedRuntimeError("appNotFound(Private Secret Window)"); got == "Windows runtime operation failed." || strings.Contains(got, "Private Secret Window") {
		t.Fatalf("app lookup diagnostic was not reduced to a safe capability message: %q", got)
	}
	if got := boundedRuntimeError("Windows semantic scroll operation failed; refresh with get_app_state before retrying because the operation may have been applied."); got == "Windows runtime operation failed." {
		t.Fatal("known actionable scroll error was over-sanitized")
	}
}

func TestMCPToolsCallRejectsMalformedParams(t *testing.T) {
	cases := []struct {
		name   string
		params any
		want   string
	}{
		{name: "missing", params: nil, want: "tools/call params must be an object"},
		{name: "null", params: nil, want: "tools/call params must be an object"},
		{name: "array", params: []any{}, want: "params must be an object"},
		{name: "missing name", params: map[string]any{}, want: "tools/call params.name must be a non-empty string"},
		{name: "bad name", params: map[string]any{"name": 1}, want: "tools/call params.name must be a non-empty string"},
		{name: "empty name", params: map[string]any{"name": "  "}, want: "tools/call params.name must be a non-empty string"},
		{name: "bad arguments", params: map[string]any{"name": "list_apps", "arguments": []any{}}, want: "tools/call params.arguments must be an object"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			request := map[string]any{"jsonrpc": "2.0", "id": 1.0, "method": "tools/call"}
			if testCase.name != "missing" {
				request["params"] = testCase.params
			}
			response := handleMCPRequest(request, newService())
			errObject, ok := response["error"].(map[string]any)
			if !ok || errObject["code"] != -32602 || errObject["message"] != testCase.want {
				t.Fatalf("response = %#v, want -32602 %q", response, testCase.want)
			}
		})
	}
	valid := handleMCPRequest(map[string]any{
		"jsonrpc": "2.0",
		"id":      1.0,
		"method":  "tools/call",
		"params":  map[string]any{"name": "not_a_tool"},
	}, newService())
	if _, ok := valid["result"]; !ok {
		t.Fatalf("valid tools/call shape was not dispatched: %#v", valid)
	}
}

func TestElementIndexRequiresGenerationBoundStringReference(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","element_index":0}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parseElementIndexArgument(args, true); err == nil || err.Error() != targetChangedMessage {
		t.Fatalf("numeric element_index error = %v, want %q", err, targetChangedMessage)
	}
	valid := map[string]any{"element_index": "s-0000000000000001:14"}
	if got, err := parseElementIndexArgument(valid, true); err != nil || got != "s-0000000000000001:14" {
		t.Fatalf("valid element reference = (%q, %v)", got, err)
	}
	if _, err := parseElementIndexArgument(map[string]any{"element_index": "s-0000000000000001:1.5"}, true); err == nil || err.Error() != targetChangedMessage {
		t.Fatalf("fractional element reference error = %v, want %q", err, targetChangedMessage)
	}
}

func TestMCPRejectsMalformedRequestEnvelope(t *testing.T) {
	cases := []map[string]any{
		nil,
		{"id": 1.0},
		{"id": 1.0, "method": 7.0},
		{"id": 1.0, "method": "  "},
	}
	for index, request := range cases {
		response := handleMCPRequest(request, newService())
		errorObject, ok := response["error"].(map[string]any)
		if !ok || errorObject["code"] != -32600 || errorObject["message"] != "Invalid Request" {
			t.Fatalf("case %d response = %#v, want Invalid Request", index, response)
		}
	}
	unknown := handleMCPRequest(map[string]any{"jsonrpc": "2.0", "id": 1.0, "method": strings.Repeat("x", 2048)}, newService())
	unknownError, ok := unknown["error"].(map[string]any)
	if !ok || unknownError["message"] != "Method not found" {
		t.Fatalf("unknown method response = %#v, want bounded method error", unknown)
	}
}

func TestMCPValidatesVersionIDsAndNotifications(t *testing.T) {
	invalidVersions := []any{nil, "1.0", 2.0}
	for index, rawVersion := range invalidVersions {
		request := map[string]any{"id": 1.0, "method": "ping"}
		if rawVersion != nil {
			request["jsonrpc"] = rawVersion
		}
		response := handleMCPRequest(request, newService())
		errorObject, ok := response["error"].(map[string]any)
		if !ok || errorObject["code"] != -32600 || errorObject["message"] != "Invalid Request" {
			t.Fatalf("version case %d response = %#v, want Invalid Request", index, response)
		}
	}
	for _, invalidID := range []any{nil, true, []any{1}, map[string]any{"id": 1}, json.Number(strings.Repeat("9", maxMCPIDLength+1))} {
		response := handleMCPRequest(map[string]any{"jsonrpc": "2.0", "id": invalidID, "method": "ping"}, newService())
		errorObject, ok := response["error"].(map[string]any)
		if !ok || errorObject["code"] != -32600 {
			t.Fatalf("invalid id %#v response = %#v, want Invalid Request", invalidID, response)
		}
	}
	if response := handleMCPRequest(map[string]any{"jsonrpc": "2.0", "method": "ping"}, newService()); response != nil {
		t.Fatalf("notification returned a response: %#v", response)
	}
	if response := handleMCPRequest(map[string]any{"jsonrpc": "2.0", "method": "tools/call", "params": map[string]any{"name": "list_apps"}}, newService()); response != nil {
		t.Fatalf("tool notification returned a response: %#v", response)
	}
	for _, notification := range []map[string]any{
		{"method": "ping"},
		{"jsonrpc": "1.0", "method": "ping"},
		{"jsonrpc": "2.0", "method": "tools/call", "params": []any{}},
	} {
		if response := handleMCPRequest(notification, newService()); response != nil {
			t.Fatalf("notification returned a response: request=%#v response=%#v", notification, response)
		}
	}
}

func TestMCPRunRejectsNonObjectPayloads(t *testing.T) {
	input := "[]\nnull\n{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n"
	var output bytes.Buffer
	if err := runMCP(strings.NewReader(input), &output); err != nil {
		t.Fatalf("runMCP returned error: %v", err)
	}
	decoder := json.NewDecoder(&output)
	var responses []map[string]any
	for {
		var response map[string]any
		err := decoder.Decode(&response)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("invalid response JSON: %v", err)
		}
		responses = append(responses, response)
	}
	if len(responses) != 3 {
		t.Fatalf("response count = %d, want 3 (array, null, one request; notification omitted): %s", len(responses), output.String())
	}
	for index := 0; index < 2; index++ {
		errorObject, ok := responses[index]["error"].(map[string]any)
		if !ok || errorObject["code"] != float64(-32600) {
			t.Fatalf("invalid payload response %d = %#v, want -32600", index, responses[index])
		}
	}
	if result, ok := responses[2]["result"].(map[string]any); !ok || len(result) != 0 {
		t.Fatalf("ping response = %#v, want empty result", responses[2])
	}
}

func TestMCPInitializeResponseContainsToolsCapability(t *testing.T) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      float64(1),
		"method":  "initialize",
		"params":  map[string]any{},
	}
	response := handleMCPRequest(request, newService())
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result: %#v", response)
	}
	if result["serverInfo"].(map[string]any)["version"] != version {
		t.Fatalf("serverInfo version = %#v, want %q", result["serverInfo"].(map[string]any)["version"], version)
	}
	capabilities := result["capabilities"].(map[string]any)
	if _, ok := capabilities["tools"]; !ok {
		t.Fatalf("missing tools capability: %#v", capabilities)
	}
}

func TestWindowsRuntimeAppSelectionNeverLaunches(t *testing.T) {
	if strings.Contains(windowsRuntimeScript, "UseShellExecute") || strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
		t.Fatal("Windows runtime must not launch a model-selected process, URL, or shell target")
	}
	if !strings.Contains(windowsRuntimeScript, "function Resolve-App([string]$query)") || !strings.Contains(windowsRuntimeScript, "throw \"appNotFound(`\"$query`\")\"") {
		t.Fatal("Windows app selection must fail closed when no existing process matches")
	}
}

func TestWindowsRuntimePinnedSelectorAndEnumerationAreBounded(t *testing.T) {
	for _, marker := range []string{
		"function Test-ProcessMatchesSelector($process, [string]$query)",
		"if (-not (Test-ProcessMatchesSelector $process ([string]$operation.app)))",
		"maxEnumeratedNodes = $script:AccessibilityTreeMaxEnumeratedNodeCount",
		"$state.enumeratedNodes = $state.enumeratedNodes + 1",
		"Test-IntegerRuntimeIdValue $runtimePart",
		"function Get-AllElements($root, [int]$MaxElements = $script:MaxRuntimeElementSearchCount)",
		"$items.Count -lt $MaxElements",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime bounded identity/enumeration contract missing %q", marker)
		}
	}
	renderStart := strings.Index(windowsRuntimeScript, "function Render-Tree")
	if renderStart < 0 {
		t.Fatal("Render-Tree is missing")
	}
	renderEnd := strings.Index(windowsRuntimeScript[renderStart:], "function Test-BitmapHasVisiblePixels")
	if renderStart < 0 || renderEnd < 0 {
		t.Fatal("could not bound Render-Tree for runtime-ID fallback review")
	}
	render := windowsRuntimeScript[renderStart : renderStart+renderEnd]
	if strings.Contains(render, "[guid]::NewGuid") {
		t.Fatal("Render-Tree must not invent actionable GUID identities when runtime IDs are unavailable")
	}
}

func TestWindowsRuntimeForegroundScreenshotRequiresExactTarget(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Capture-WindowPngBase64")
	if start < 0 {
		t.Fatal("screenshot capture function is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Get-FocusedSummary")
	if start < 0 || endOffset < 0 {
		t.Fatal("could not bound screenshot capture")
	}
	capture := windowsRuntimeScript[start : start+endOffset]
	if !strings.Contains(capture, "if ($foregroundHwnd -eq [IntPtr]$hwnd -and (Test-HwndDescendantOf") ||
		!strings.Contains(capture, "if (-not (Test-HwndDescendantOf ([IntPtr]$hwnd) $foregroundHwnd))") {
		t.Fatal("foreground screenshot path must require exact target/descendant provenance at copy time")
	}
	copyOffset := strings.Index(capture, "CopyFromScreen")
	revalidateOffset := strings.LastIndex(capture[:copyOffset], "Assert-SnapshotCaptureTarget")
	if copyOffset < 0 || revalidateOffset < 0 {
		t.Fatal("foreground screenshot must revalidate target before desktop copy")
	}
}

func TestMCPIDPolicyBoundsAndRejectsNull(t *testing.T) {
	if validMCPID(nil) {
		t.Fatal("null request IDs must be rejected; notifications omit id")
	}
	if !validMCPID("short-id") || !validMCPID(json.Number("123.5")) {
		t.Fatal("valid bounded string/number IDs were rejected")
	}
	if validMCPID(strings.Repeat("x", maxMCPIDLength+1)) || validMCPID(json.Number(strings.Repeat("9", maxMCPIDLength+1))) {
		t.Fatal("oversized IDs were accepted")
	}
}

func TestCLIHelpMentionsWindowsRuntime(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"--help"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Open Computer Use for Windows") {
		t.Fatalf("help text did not mention Windows runtime:\n%s", out.String())
	}
}

func TestWindowsTypeTextSchemaRemainsFocusOnly(t *testing.T) {
	tool := findToolDefinition(t, "type_text")
	properties, ok := tool.InputSchema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("type_text properties = %#v", tool.InputSchema["properties"])
	}
	if len(properties) != 2 {
		t.Fatalf("type_text must retain exactly app and text properties, got %#v", properties)
	}
	for _, key := range []string{"app", "text"} {
		if _, ok := properties[key]; !ok {
			t.Fatalf("type_text schema is missing %q: %#v", key, properties)
		}
	}
	if _, ok := properties["element_index"]; ok {
		t.Fatal("type_text must not add an element_index field under the selected focus-only contract")
	}
	required, ok := tool.InputSchema["required"].([]string)
	if !ok || strings.Join(required, ",") != "app,text" {
		t.Fatalf("type_text required fields = %#v, want [app text]", tool.InputSchema["required"])
	}
	for _, marker := range []string{
		"current focused writable text control",
		"Click/select the field first",
		"never chooses a substitute control",
		"set_value",
	} {
		if !strings.Contains(tool.Description, marker) {
			t.Fatalf("type_text description must document %q: %s", marker, tool.Description)
		}
	}
}

func TestWindowsTypeTextUsesOnlyValidatedFocusedTarget(t *testing.T) {
	for _, marker := range []string{
		"$TypeTextTargetError =",
		"$TypeTextFallbackError =",
		"$TypeTextDeliveryError =",
		"function Test-SameAutomationElement",
		"compare only validated runtime IDs",
		"return (Same-RuntimeId $leftRuntimeId $rightRuntimeId)",
		"function Test-AutomationElementDescendantOf",
		"function Test-FocusedTextElement",
		"function Test-TextEntryControlType",
		"Test-HwndOwnedByProcess $nativeHwnd $process",
		"Test-HwndDescendantOf $rootHwnd $nativeHwnd",
		"function Get-ValidatedFocusedTextTarget",
		"[Windows.Automation.AutomationElement]::FocusedElement",
		"function Assert-FocusedTextTarget",
		"Assert-FocusedTextTarget $process $rootHwnd $element $hwnd",
		"Invoke-FocusedValuePatternText $process $rootHwnd $text $target.element",
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK",
		"type_text requires a focused writable text control",
		"type_text could not write to the focused text control",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows type_text focus contract missing %q", marker)
		}
	}

	typeStart := strings.Index(windowsRuntimeScript, "$TypeTextTargetError")
	dispatchStart := strings.Index(windowsRuntimeScript, "            \"type_text\" {")
	focusStart := strings.Index(windowsRuntimeScript, "function Test-SameAutomationElement")
	focusEnd := strings.Index(windowsRuntimeScript, "function Resolve-AppPostTargetHandle")
	deliveryStart := strings.Index(windowsRuntimeScript, "function Assert-FocusedTextTarget")
	deliveryEnd := strings.Index(windowsRuntimeScript, "# Get-Content defaults to the system ANSI code page")
	if typeStart < 0 || focusStart < 0 || focusEnd < 0 || deliveryStart < 0 || deliveryEnd < 0 || dispatchStart < 0 || typeStart >= focusStart || focusStart >= focusEnd || deliveryStart >= deliveryEnd || deliveryEnd >= dispatchStart {
		t.Fatal("could not bound the Windows type_text implementation")
	}
	typeImplementation := windowsRuntimeScript[focusStart:focusEnd] + windowsRuntimeScript[deliveryStart:deliveryEnd]
	for _, forbidden := range []string{
		"Get-AllElements",
		"Get-MainElement",
		"Find-TextEntryElement",
		"Find-TextEntryWindowHandle",
		"Test-TextWindowHandleCandidate",
		"Send-Text $process",
		"WM_CHAR",
		"SendInputRecords",
		"SetForegroundWindow",
		"SetFocus()",
		"Clipboard",
	} {
		if strings.Contains(typeImplementation, forbidden) {
			t.Fatalf("type_text implementation must not use substitute or implicit-input path %q", forbidden)
		}
	}

	if strings.Count(typeImplementation, "[Windows.Automation.AutomationElement]::FocusedElement") < 2 {
		t.Fatal("type_text must read the focused element again immediately before delivery")
	}
	if !strings.Contains(typeImplementation, "ControlType.Edit") || !strings.Contains(typeImplementation, "ControlType.Document") {
		t.Fatal("type_text must restrict implicit targets to writable text control types")
	}

	branchEndOffset := strings.Index(windowsRuntimeScript[dispatchStart:], "            \"press_key\" {")
	if branchEndOffset < 0 {
		t.Fatal("could not bound the type_text dispatch branch")
	}
	branch := windowsRuntimeScript[dispatchStart : dispatchStart+branchEndOffset]
	if !strings.Contains(branch, "Invoke-TypeText $process $hwnd $operation.text") {
		t.Fatal("type_text dispatch must pass the snapshot-bound window handle to the focused-target implementation")
	}
	if strings.Contains(branch, "Send-Text") || strings.Contains(branch, "$operation.element") {
		t.Fatal("type_text dispatch must not fall back to top-level text messages or an element record")
	}

	if !strings.Contains(windowsRuntimeScript, "function Get-BoundedRuntimeError($exception)") || strings.Contains(windowsRuntimeScript, "$PSItem.ScriptStackTrace") {
		t.Fatal("runtime error boundary must normalize errors without exposing script stack traces")
	}
	if !strings.Contains(windowsRuntimeScript, "Windows runtime operation failed.") {
		t.Fatal("runtime error boundary must have a fixed fallback message")
	}
}

func TestWindowsRuntimeForegroundActionsRequireOptIn(t *testing.T) {
	for _, marker := range []string{
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS",
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK",
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT",
		"OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS",
		"SendInputRecords",
		"KEYEVENTF_EXTENDEDKEY",
		"ChildWindowFromPointEx",
		"WindowFromPoint",
		"BM_CLICK",
		"Send-NativeButtonClick",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime must retain opt-in marker %q", marker)
		}
	}
	if strings.Contains(windowsRuntimeScript, "AttachThreadInput") {
		t.Fatal("Windows interactive input must not bypass foreground policy with AttachThreadInput")
	}
	if strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") || strings.Contains(windowsRuntimeScript, "UseShellExecute") {
		t.Fatal("Windows runtime must never launch a model-selected app or shell target")
	}
	if !strings.Contains(windowsRuntimeScript, "appNotFound(") {
		t.Fatal("Windows runtime must fail closed when an app is not already running")
	}
	if !strings.Contains(serverInstructions, "does not auto-launch apps, perform SetFocus, or use UIA text fallback by default") {
		t.Fatal("MCP instructions must document the Windows background-focus policy")
	}
	if !strings.Contains(serverInstructions, "Global click and physical drag require both") {
		t.Fatal("MCP instructions must document the separate global pointer authorization")
	}
	if !strings.Contains(serverInstructions, "Element-targeted coordinate fallback requires a valid finite snapshot frame or explicit finite x/y") {
		t.Fatal("MCP instructions must document the missing-frame click boundary")
	}
	if !strings.Contains(serverInstructions, "`press_key` is rejected unless the foreground-input flag is set") {
		t.Fatal("MCP instructions must document keyboard input authorization")
	}
	for _, marker := range []string{
		"Windows `type_text` requires the current focused control",
		"click/select the field first",
		"never searches the current UIA tree for a substitute control",
		"top-level keyboard messages",
	} {
		if !strings.Contains(serverInstructions, marker) {
			t.Fatalf("MCP instructions must document the type_text focus contract %q", marker)
		}
	}
}

func TestWindowsRuntimeDoesNotReplayRejectedInputBatches(t *testing.T) {
	for _, marker := range []string{
		"if ([int]$accepted -eq $recordCount)",
		"SendInput does not provide a reliable error code for rejected records",
		"No retry was attempted because SendInput submission is not safely replayable",
		"Submit-InteractiveInputRecords $records \"key press\"",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime batch failure contract missing %q", marker)
		}
	}
	for _, forbidden := range []string{
		"singleRecord",
		"$singleAccepted",
		"$cleanup = @",
		"SendInputRecords($cleanupRecords)",
		"_lastSendInputError",
		"GetLastSendInputError",
		"Marshal.GetLastWin32Error()",
	} {
		if strings.Contains(windowsRuntimeScript, forbidden) {
			t.Fatalf("Windows runtime must not submit an extra keyboard cleanup batch %q", forbidden)
		}
	}
}

func TestWindowsRuntimeSeparatesPointerAndKeyboardAuthorization(t *testing.T) {
	for _, marker := range []string{
		"function Test-InteractivePointerInputEnabled()",
		"Assert-InteractiveDragPath $process $hwnd $fromX $fromY $toX $toY $steps",
		"if (Test-InteractivePointerInputEnabled)",
		"function Test-ProcessOwnsForegroundWindow($process, [IntPtr]$expectedHwnd)",
		"Test-HwndDescendantOf $hwnd $hitWindow",
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS",
		"if (-not [OCUWin32]::SetForegroundWindow($hwnd))",
		"focus it with an authorized global click",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime authorization boundary missing %q", marker)
		}
	}
	if strings.Contains(windowsRuntimeScript, `if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT") {
					Send-InteractiveDrag`) {
		t.Fatal("drag must not select global input from keyboard authorization alone")
	}
}

func TestWindowsRuntimeKeepsBackgroundDragAppScoped(t *testing.T) {
	const backgroundStart = "function Send-BackgroundDrag($process"
	const backgroundEnd = "function Send-Scroll"
	start := strings.Index(windowsRuntimeScript, backgroundStart)
	if start < 0 {
		t.Fatal("Windows runtime must retain an explicitly named app-scoped background drag helper")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], backgroundEnd)
	if endOffset < 0 {
		t.Fatal("could not bound background drag helper")
	}
	backgroundDrag := windowsRuntimeScript[start : start+endOffset]
	for _, marker := range []string{
		"Assert-AppScopedMessageTarget $process $hwnd",
		"if (-not [OCUWin32]::PostMessage",
		"background drag mouse-down message",
		"background drag mouse-up message",
	} {
		if !strings.Contains(backgroundDrag, marker) {
			t.Fatalf("background drag safety contract missing %q", marker)
		}
	}
	if strings.Contains(backgroundDrag, "SendInputRecords") {
		t.Fatal("background drag must not become physical global input")
	}
	if strings.Contains(windowsRuntimeScript, "function Send-Drag") {
		t.Fatal("legacy unguarded background drag helper must not remain")
	}

	dragStart := strings.Index(windowsRuntimeScript, `"drag" {`)
	if dragStart < 0 {
		t.Fatal("could not find drag dispatch branch")
	}
	dragEndOffset := strings.Index(windowsRuntimeScript[dragStart:], `"type_text" {`)
	if dragEndOffset < 0 {
		t.Fatal("could not bound drag dispatch branch")
	}
	dragBranch := windowsRuntimeScript[dragStart : dragStart+dragEndOffset]
	for _, marker := range []string{
		"if (Test-InteractivePointerInputEnabled)",
		"Send-InteractiveDrag $process $hwnd $fromX $fromY $toX $toY",
		"Send-BackgroundDrag $process $hwnd $fromX $fromY $toX $toY",
	} {
		if !strings.Contains(dragBranch, marker) {
			t.Fatalf("drag dispatch contract missing %q", marker)
		}
	}
}

func TestWindowsRuntimeRoutesGlobalClickExplicitly(t *testing.T) {
	dispatchRoot := strings.Index(windowsRuntimeScript, "        switch ($operation.tool) {")
	if dispatchRoot < 0 {
		t.Fatal("could not find action dispatch root")
	}
	clickStart := strings.Index(windowsRuntimeScript[dispatchRoot:], `"click" {`)
	if clickStart >= 0 {
		clickStart += dispatchRoot
	}
	if clickStart < 0 {
		t.Fatal("could not find click dispatch branch")
	}
	clickEndOffset := strings.Index(windowsRuntimeScript[clickStart:], `"perform_secondary_action" {`)
	if clickEndOffset < 0 {
		t.Fatal("could not bound click dispatch branch")
	}
	clickBranch := windowsRuntimeScript[clickStart : clickStart+clickEndOffset]
	if strings.Count(clickBranch, "Send-InteractiveMouseClick") != 1 {
		t.Fatal("only explicit click_method 'global' may use physical global input")
	}
	globalStart := strings.Index(clickBranch, `} elseif ($clickMethod -eq "global") {`)
	if globalStart < 0 {
		t.Fatal("could not find explicit global click branch")
	}
	globalEndOffset := strings.Index(clickBranch[globalStart:], `} elseif ($clickMethod -eq "sky_click") {`)
	if globalEndOffset < 0 {
		t.Fatal("could not bound explicit global click branch")
	}
	if !strings.Contains(clickBranch[globalStart:globalStart+globalEndOffset], "Send-InteractiveMouseClick") {
		t.Fatal("explicit global click branch must use physical global input")
	}
}

func TestWindowsPressKeyRejectsWithoutForegroundAuthorization(t *testing.T) {
	for _, marker := range []string{
		`"press_key" {`,
		`if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT"))`,
		"Interactive Windows keyboard input is disabled by default",
		"Send-InteractiveKey $process $hwnd $operation.key",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows press_key authorization guard missing %q", marker)
		}
	}
	if strings.Contains(windowsRuntimeScript, "Send-Key") {
		t.Fatal("Windows press_key must not retain an unauthorized PostMessage keyboard fallback")
	}
}

func TestWindowsRuntimeValidatesInteractiveDragPath(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "function Assert-InteractiveDragPath") {
		t.Fatal("interactive drag must validate the full pointer path")
	}
	if !strings.Contains(windowsRuntimeScript, "for ($i = 0; $i -le $steps; $i++)") {
		t.Fatal("interactive drag path validation must include both endpoints")
	}
	if !strings.Contains(windowsRuntimeScript, "Ensure-InteractivePointerTarget $process $hwnd $x $y") {
		t.Fatal("interactive drag path validation must check each sampled point")
	}
}

func TestWindowsAppPostNativeButtonContract(t *testing.T) {
	for _, marker := range []string{
		"$BM_CLICK = 0x00F5",
		"function Send-NativeButtonClick",
		"Test-NativeButtonElement $element",
		"Send-NativeButtonClick $process $targetHwnd ($clickCount)",
		"requires a native HWND target for this WPF element",
		"cannot target WPF coordinate input without a native child HWND",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows app_post contract missing %q", marker)
		}
	}
}

func TestUTF8EncodingInPowerShellScript(t *testing.T) {
	// Verify that the PowerShell script sets UTF-8 encoding
	if !strings.Contains(windowsRuntimeScript, "$OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set $OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
	if !strings.Contains(windowsRuntimeScript, "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set [Console]::OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
}

func TestWindowsRuntimeScreenshotCaptureContract(t *testing.T) {
	for _, marker := range []string{
		"[bool]$IncludeImage = $false",
		"[OCUWin32]::PrintWindow",
		"$foregroundHwnd = [OCUWin32]::GetForegroundWindow()",
		"if ($foregroundHwnd -eq [IntPtr]$hwnd -and (Test-HwndDescendantOf",
		"Test-BitmapHasVisiblePixels",
		"Normalize-BitmapAlpha",
		"CopyFromScreen",
		"function Assert-SnapshotCaptureTarget",
		"Resolve-InteractiveWindowTarget $process",
		"$ExpectedStartTimeTicks",
		"screenshotPngBase64 = Capture-WindowPngBase64 $bounds $targetHwnd $IncludeImage $process $startTimeTicks",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows screenshot contract missing %q", marker)
		}
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image)") {
		t.Fatal("get_app_state include_image was not forwarded to Build-Snapshot")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-SnapshotForProcess $process $operation.app $null $AccessibilityTreeMaxNodeCount $AccessibilityTreeMaxDepth $true $hwnd ([int64]$operation.expectedProcessStartTimeTicks)") {
		t.Fatal("action refreshes must retain the validated process, HWND, identity, and screenshots")
	}
}
func TestWindowsActionRefreshRetainsSnapshotWindowIdentity(t *testing.T) {
	for _, marker := range []string{
		"[IntPtr]$ExpectedHwnd = [IntPtr]::Zero",
		"[int64]$ExpectedStartTimeTicks = 0",
		"if ($ExpectedHwnd -ne [IntPtr]::Zero -and $targetHwnd -ne $ExpectedHwnd)",
		"if ($ExpectedStartTimeTicks -gt 0 -and $startTimeTicks -ne $ExpectedStartTimeTicks)",
		"function Assert-SnapshotCaptureTarget",
		"$target = Resolve-InteractiveWindowTarget $process",
		"Build-SnapshotForProcess $process $operation.app $null $AccessibilityTreeMaxNodeCount $AccessibilityTreeMaxDepth $true $hwnd ([int64]$operation.expectedProcessStartTimeTicks)",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("action refresh identity contract missing %q", marker)
		}
	}
}

func TestWindowsRuntimeRenderTreeUsesInvocationLocalState(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Render-Tree")
	if start < 0 {
		t.Fatal("Render-Tree is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Test-BitmapHasVisiblePixels")
	if endOffset < 0 {
		t.Fatal("could not bound Render-Tree")
	}
	renderTree := windowsRuntimeScript[start : start+endOffset]
	for _, marker := range []string{
		"$renderState = [pscustomobject]@{",
		"function Visit($state, $node, [int]$depth)",
		"Visit $state $children.Item($i) ($depth + 1)",
		"Visit $renderState $element 0",
	} {
		if !strings.Contains(renderTree, marker) {
			t.Fatalf("Render-Tree local-state contract missing %q", marker)
		}
	}
	for _, forbidden := range []string{"$script:nextIndex", "$script:MaxTreeNodes", "$script:records", "$script:lines", "$script:visited", "$script:windowBounds"} {
		if strings.Contains(renderTree, forbidden) {
			t.Fatalf("Render-Tree still uses mutable script state %q", forbidden)
		}
	}
}

func TestWindowsRuntimeIdentityFieldsFailClosed(t *testing.T) {
	for _, marker := range []string{
		"function Get-SnapshotIdentity($operation, [bool]$required)",
		"$present.Count -ne $names.Count",
		"Test-IntegerInRange $pidValue",
		"Test-IntegerInRange $startValue",
		"Test-IntegerInRange $hwndValue",
		"[void](Get-SnapshotIdentity $operation $false)",
		"$identity = Get-SnapshotIdentity $operation $true",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("snapshot identity validation contract missing %q", marker)
		}
	}
	if !strings.Contains(windowsRuntimeScript, "$identity = Get-SnapshotIdentity $operation $false") {
		t.Fatal("pinned get_app_state must distinguish absent identity from malformed identity")
	}
}

func TestWindowsRuntimeCaptureAlwaysPinsProcessAndWindow(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Capture-WindowPngBase64")
	if start < 0 {
		t.Fatal("screenshot capture function is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Get-FocusedSummary")
	if endOffset < 0 {
		t.Fatal("could not bound screenshot capture function")
	}
	capture := windowsRuntimeScript[start : start+endOffset]
	if !strings.Contains(capture, "if ($null -eq $process)") || !strings.Contains(capture, "Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds") {
		t.Fatal("every screenshot capture must require process-bound target validation")
	}
	if strings.Contains(capture, "elseif ($null -ne $hwnd -and [OCUWin32]::IsWindow") {
		t.Fatal("screenshot capture must not retain an unscoped HWND fallback")
	}
}

func TestWindowsRuntimeScreenshotFallbackFailsClosedForBackgroundWindows(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Capture-WindowPngBase64")
	if start < 0 {
		t.Fatal("screenshot capture function is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Get-FocusedSummary")
	if endOffset < 0 {
		t.Fatal("could not bound screenshot capture function")
	}
	capture := windowsRuntimeScript[start : start+endOffset]
	if strings.Count(capture, "CopyFromScreen") != 1 {
		t.Fatalf("background screenshot fallback must not copy an arbitrary desktop rectangle: %q", capture)
	}
	fallback := strings.Index(capture, "if (-not $captured -or -not (Test-BitmapHasVisiblePixels $bitmap))")
	if fallback < 0 || strings.Contains(capture[fallback:], "CopyFromScreen") {
		t.Fatal("PrintWindow failure/blank output must return no image instead of copying screen pixels")
	}
	if !strings.Contains(capture, "if (-not (Test-HwndDescendantOf ([IntPtr]$hwnd) $foregroundHwnd))") {
		t.Fatal("foreground screen capture must revalidate the HWND immediately before CopyFromScreen")
	}
}

func TestWindowsRuntimeBitmapAlphaNormalizationBatched(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Normalize-BitmapAlpha")
	if start < 0 {
		t.Fatal("Normalize-BitmapAlpha function is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Capture-WindowPngBase64")
	if endOffset < 0 {
		t.Fatal("could not bound Normalize-BitmapAlpha function")
	}
	normalize := windowsRuntimeScript[start : start+endOffset]
	for _, marker := range []string{
		"$stepX = [Math]::Max(1, [int]($bitmap.Width / 32))",
		"$stepY = [Math]::Max(1, [int]($bitmap.Height / 32))",
		".GetPixel(",
		"LockBits(",
		"[System.Drawing.Imaging.ImageLockMode]::ReadWrite",
		"[System.Drawing.Imaging.PixelFormat]::Format32bppArgb",
		"[System.Runtime.InteropServices.Marshal]::Copy",
		"UnlockBits(",
	} {
		if !strings.Contains(normalize, marker) {
			t.Fatalf("bitmap alpha normalization contract missing %q", marker)
		}
	}
	if strings.Count(normalize, ".GetPixel(") != 1 {
		t.Fatalf("alpha normalization must only sample pixels through the 32x32 gate: %q", normalize)
	}
	if strings.Contains(normalize, ".SetPixel(") {
		t.Fatal("alpha normalization must not rewrite pixels through per-pixel SetPixel interop")
	}
	if strings.Count(normalize, "[System.Runtime.InteropServices.Marshal]::Copy") < 2 {
		t.Fatal("alpha normalization must copy the buffer in and back out via Marshal.Copy")
	}
	lockBits := strings.Index(normalize, "LockBits(")
	unlockBits := strings.Index(normalize, "UnlockBits(")
	if lockBits < 0 || unlockBits < 0 || unlockBits < lockBits {
		t.Fatal("alpha normalization must lock the bitmap bits before unlocking them")
	}
	finally := strings.Index(normalize[lockBits:], "} finally {")
	if finally < 0 || unlockBits <= lockBits+finally {
		t.Fatal("alpha normalization must unlock the bitmap bits in a finally block")
	}
}

func TestWindowsRuntimePrintWindowRenderFullContentRetry(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Capture-WindowPngBase64")
	if start < 0 {
		t.Fatal("screenshot capture function is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Get-FocusedSummary")
	if endOffset < 0 {
		t.Fatal("could not bound screenshot capture function")
	}
	capture := windowsRuntimeScript[start : start+endOffset]
	flagsZero := strings.Index(capture, "[OCUWin32]::PrintWindow([IntPtr]$hwnd, $hdc, 0)")
	renderFullContent := strings.Index(capture, "[OCUWin32]::PrintWindow([IntPtr]$hwnd, $hdc, 2)")
	failClosed := strings.Index(capture, "if (-not $captured -or -not (Test-BitmapHasVisiblePixels $bitmap))")
	if flagsZero < 0 {
		t.Fatal("background capture must first attempt PrintWindow with flags=0")
	}
	if renderFullContent < 0 {
		t.Fatal("background capture must retry once with PW_RENDERFULLCONTENT (flags=2)")
	}
	if failClosed < 0 {
		t.Fatal("background capture must keep the fail-closed fallback check")
	}
	if !(flagsZero < renderFullContent && renderFullContent < failClosed) {
		t.Fatalf("PrintWindow retry ordering violated: flags=0 at %d, flags=2 at %d, fail-closed at %d", flagsZero, renderFullContent, failClosed)
	}
	if strings.Count(capture, "Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds") < 2 {
		t.Fatal("PrintWindow retry must revalidate the capture target identity before repainting")
	}
	if !strings.Contains(capture, "$graphics.Clear([System.Drawing.Color]::Black)") {
		t.Fatal("PrintWindow retry must reset the shared bitmap to black before repainting")
	}
	if strings.Count(capture, "CopyFromScreen") != 1 {
		t.Fatalf("retry path must not introduce additional desktop copies: %q", capture)
	}
	for _, forbidden := range []string{"CreateDC", "\"Screen\"", "GetDesktopWindow"} {
		if strings.Contains(capture, forbidden) {
			t.Fatalf("background capture must stay HWND-scoped and fail closed, found %q", forbidden)
		}
	}
}

func TestWindowsNativeTextDeliveryChecksPostconditionWithoutFallback(t *testing.T) {
	start := strings.Index(windowsRuntimeScript, "function Send-TextToEditHandle")
	if start < 0 {
		t.Fatal("native text delivery helper is missing")
	}
	endOffset := strings.Index(windowsRuntimeScript[start:], "function Resolve-App")
	if endOffset < 0 {
		t.Fatal("could not bound native text delivery helper")
	}
	helper := windowsRuntimeScript[start : start+endOffset]
	for _, marker := range []string{
		"attempted = $false",
		"$attempted = $true",
		"$currentLength = [int]$current.Length",
		"[OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr]$currentLength, [IntPtr]$currentLength)",
		"[OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL",
		"$after -ne ($current + $text)",
		"attempted = $true; succeeded = $false",
	} {
		if !strings.Contains(helper, marker) {
			t.Fatalf("native text delivery contract missing %q", marker)
		}
	}
	if strings.Contains(helper, "[IntPtr](-1)") {
		t.Fatal("native text append must not use the -1 selection sentinel")
	}
	if strings.Count(helper, "Assert-FocusedTextTarget $process $rootHwnd $element $hwnd") < 3 {
		t.Fatal("native text delivery must revalidate focus, element identity, and HWND around both mutating messages")
	}
	selectionStart := strings.Index(helper, "$currentLength = [int]$current.Length")
	if selectionStart < 0 {
		t.Fatal("native text selection setup is missing")
	}
	selectionHelper := helper[selectionStart:]
	focusMarker := "[void](Assert-FocusedTextTarget $process $rootHwnd $element $hwnd)"
	firstFocusCheck := strings.Index(selectionHelper, focusMarker)
	secondFocusCheck := -1
	if firstFocusCheck >= 0 {
		secondFocusCheck = strings.Index(selectionHelper[firstFocusCheck+len(focusMarker):], focusMarker)
		if secondFocusCheck >= 0 {
			secondFocusCheck += firstFocusCheck + len(focusMarker)
		}
	}
	attemptMarker := strings.Index(selectionHelper, "$attempted = $true")
	selectionMessage := strings.Index(selectionHelper, "[OCUWin32]::SendMessage($hwnd, $EM_SETSEL")
	replacementMessage := strings.Index(selectionHelper, "[OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL")
	if firstFocusCheck < 0 || secondFocusCheck < 0 || selectionMessage < 0 || attemptMarker < 0 || replacementMessage < 0 || firstFocusCheck > selectionMessage || selectionMessage > secondFocusCheck || secondFocusCheck > attemptMarker || attemptMarker > replacementMessage {
		t.Fatal("native text attempted marker must follow selection/focus validation and precede EM_REPLACESEL")
	}
	if strings.Contains(helper, "$attempted = $true\n        [void](Assert-FocusedTextTarget") {
		t.Fatal("native text must not mark an attempt before pre-mutation validation")
	}
	if strings.Contains(helper, "$WM_SETTEXT") {
		t.Fatal("native text failure must not retry through WM_SETTEXT")
	}
	typeTextStart := strings.Index(windowsRuntimeScript, "function Invoke-TypeText")
	if typeTextStart < 0 {
		t.Fatal("type_text delivery implementation is missing")
	}
	typeTextEndOffset := strings.Index(windowsRuntimeScript[typeTextStart:], "function Get-BoundedRuntimeError")
	if typeTextEndOffset < 0 {
		t.Fatal("could not bound the type_text delivery implementation")
	}
	typeTextBody := windowsRuntimeScript[typeTextStart : typeTextStart+typeTextEndOffset]
	attemptedBranch := strings.Index(typeTextBody, "if ($nativeResult.attempted) {")
	if attemptedBranch < 0 || !strings.Contains(typeTextBody[attemptedBranch:], "throw $TypeTextDeliveryError") {
		t.Fatal("type_text must fail after an attempted native mutation instead of invoking UIA fallback")
	}
}

func TestWindowsRuntimeNumericValidationPrecedesDelivery(t *testing.T) {
	for _, marker := range []string{
		"function Test-FiniteNumber($value)",
		"function Assert-FiniteCoordinate($value, [string]$name)",
		"function Assert-ValidFrame($candidate, [string]$errorMessage, [bool]$requirePositiveSize)",
		"function Assert-OperationNumericValues($operation)",
		"[math]::Abs($rounded) -gt $MaxCoordinateMagnitude",
		"[math]::Abs($xValue) -gt $MaxCoordinateMagnitude",
		"Assert-FiniteCoordinate $operation.x \"x\"",
		"click_count must be an integer between 1 and 100.",
		"pages must be finite and in (0,100].",
		"Assert-OperationNumericValues $operation",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("PowerShell numeric validation contract missing %q", marker)
		}
	}
	validationStart := strings.Index(windowsRuntimeScript, "    Assert-OperationNumericValues $operation")
	resolveStart := strings.Index(windowsRuntimeScript[validationStart:], "        $target = Resolve-SnapshotActionTarget $operation")
	if validationStart < 0 || resolveStart < 0 {
		t.Fatal("could not establish numeric validation/target-resolution order")
	}
	if strings.Contains(windowsRuntimeScript[validationStart:validationStart+resolveStart], "Resolve-SnapshotActionTarget") {
		t.Fatal("numeric validation must precede snapshot target resolution")
	}
}

func TestWindowsRuntimeInitializationAndOperationErrorsStayStructured(t *testing.T) {
	outputStart := strings.Index(windowsRuntimeScript, "$OutputEncoding = [System.Text.Encoding]::UTF8")
	addTypeStart := strings.Index(windowsRuntimeScript, "Add-Type -AssemblyName UIAutomationClient")
	initEnd := strings.Index(windowsRuntimeScript[addTypeStart:], "Windows runtime initialization failed.")
	initPrefixStart := outputStart - 20
	if initPrefixStart < 0 {
		initPrefixStart = 0
	}
	if outputStart < 0 || addTypeStart < outputStart || initEnd < 0 || !strings.Contains(windowsRuntimeScript[initPrefixStart:outputStart], "try") {
		t.Fatal("PowerShell initialization is not inside a bounded JSON error boundary")
	}
	if strings.Contains(windowsRuntimeScript, "$PSItem.ScriptStackTrace") {
		t.Fatal("PowerShell responses must not expose ScriptStackTrace")
	}
	operationTry := strings.Index(windowsRuntimeScript, "$operationJson = [System.IO.File]::ReadAllText")
	operationDispatch := strings.Index(windowsRuntimeScript, "if ($operation.tool -eq \"list_apps\")")
	if operationTry < 0 || operationDispatch < 0 || operationTry > operationDispatch {
		t.Fatal("operation file read/parse must be inside the structured dispatch try block")
	}
	if !strings.Contains(windowsRuntimeScript, "ConvertTo-Json -Depth 50 -Compress") || !strings.Contains(windowsRuntimeScript, "Windows runtime operation failed.") {
		t.Fatal("final PowerShell JSON serialization must have a bounded fallback")
	}
}

func TestWindowsRuntimeTextLimitSupportsMaxMode(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$DefaultTextLimit = 500") {
		t.Fatal("Windows runtime should define the shared 500 character text limit")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit)") {
		t.Fatal("Windows get_app_state should pass text_limit into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq \"max\"") {
		t.Fatal("Windows runtime should support max text limit mode")
	}
	if !strings.Contains(windowsRuntimeScript, "([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth)") {
		t.Fatal("Windows get_app_state should pass tree budget into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }") {
		t.Fatal("Windows selected text should use full UIA text only in max text mode")
	}
}

func TestWindowsRuntimeTreeBudgetDefaultsMatchMacOS(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxNodeCount = 1200") {
		t.Fatal("Windows runtime should default to the shared 1200 node tree budget")
	}
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxDepth = 64") {
		t.Fatal("Windows runtime should default to the shared 64 level tree depth")
	}
	if !strings.Contains(windowsRuntimeScript, "$state.nextIndex -ge $state.maxTreeNodes -or $depth -gt $state.maxTreeDepth") {
		t.Fatal("Windows runtime should use local render state while applying tree budgets")
	}
	if strings.Contains(windowsRuntimeScript, "$script:nextIndex") || strings.Contains(windowsRuntimeScript, "$script:MaxTreeNodes") || strings.Contains(windowsRuntimeScript, "$script:records") {
		t.Fatal("Render-Tree must not use mutable script-global traversal state")
	}
}

func findToolDefinition(t *testing.T, name string) toolDefinition {
	t.Helper()
	for _, tool := range toolDefinitions() {
		if tool.Name == name {
			return tool
		}
	}
	t.Fatalf("missing tool definition %q", name)
	return toolDefinition{}
}
