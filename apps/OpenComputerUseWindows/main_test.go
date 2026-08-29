package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
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

func TestWindowsGlobalClickRequiresSnapshotBeforeRuntime(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click("Notepad", "", &x, &y, 1, "left", "global")
	if !result.IsError || result.Content[0].Text != "No app state is available for Notepad. Run get_app_state before action tools." {
		t.Fatalf("global click result = %#v", result)
	}
}

func TestWindowsTypeTextRequiresSnapshotBeforeRuntime(t *testing.T) {
	result := newService().typeText("Notepad", "hello")
	if !result.IsError || result.Content[0].Text != "No app state is available for Notepad. Run get_app_state before action tools." {
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
	service.rememberSnapshot("Fixture A", first)
	service.rememberSnapshot("Fixture B", second)

	if got := service.currentSnapshot("Fixture A"); got != first {
		t.Fatalf("exact title A snapshot = %#v, want first", got)
	}
	if got := service.currentSnapshot("Fixture B"); got != second {
		t.Fatalf("exact title B snapshot = %#v, want second", got)
	}
	if got := service.currentSnapshot("1001"); got != first {
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
		"$message -ne \"Target changed; call get_app_state again.\"",
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
		"$null -eq $frame.x",
		"[double]::IsNaN",
		"[double]::IsInfinity",
		"$values[2] -le 0 -or $values[3] -le 0",
		"Get-ScreenPoint $frame $windowBounds",
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
		"[double]::IsNaN",
		"[double]::IsInfinity",
		"$frameValues[2] -le 0 -or $frameValues[3] -le 0",
		"Get-ScreenPoint $frame $windowBounds",
		"[double]$operation.x",
		"[double]$operation.y",
	} {
		if !strings.Contains(helper, marker) {
			t.Fatalf("click point validation missing %q", marker)
		}
	}

	const clickStartMarker = `"click" {`
	clickStart := strings.Index(windowsRuntimeScript, clickStartMarker)
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

	if !strings.Contains(windowsRuntimeScript, `$message -ne "Target changed; call get_app_state again." -and $message -ne "Click requires an element with a valid frame or explicit finite x/y coordinates."`) {
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

func TestElementIndexAcceptsStringAndJSONNumber(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","element_index":0}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := optionalElementIndex(args); got != "0" {
		t.Fatalf("numeric element_index = %q, want 0", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": "14"}); got != "14" {
		t.Fatalf("string element_index = %q, want 14", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": json.Number("1.5")}); got != "" {
		t.Fatalf("fractional element_index = %q, want empty", got)
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
	capabilities := result["capabilities"].(map[string]any)
	if _, ok := capabilities["tools"]; !ok {
		t.Fatalf("missing tools capability: %#v", capabilities)
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
	deliveryEnd := strings.Index(windowsRuntimeScript, "# Read the operation file as UTF-8 explicitly.")
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

	catchStart := strings.Index(windowsRuntimeScript, "    $message = $PSItem.Exception.Message")
	if catchStart < 0 {
		t.Fatal("runtime error boundary is missing")
	}
	catchBlock := windowsRuntimeScript[catchStart:]
	for _, marker := range []string{"$message -ne $TypeTextTargetError", "$message -ne $TypeTextFallbackError", "$message -ne $TypeTextDeliveryError"} {
		if !strings.Contains(catchBlock, marker) {
			t.Fatalf("bounded type_text error must not receive a script stack trace: %q", marker)
		}
	}
}

func TestWindowsRuntimeForegroundActionsRequireOptIn(t *testing.T) {
	for _, marker := range []string{
		"OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH",
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
	clickStart := strings.Index(windowsRuntimeScript, `"click" {`)
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
		"Send-NativeButtonClick $process $targetHwnd ([int]$operation.click_count)",
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
		"if ($foregroundHwnd -eq [IntPtr]$hwnd)",
		"Test-BitmapHasVisiblePixels",
		"Normalize-BitmapAlpha",
		"CopyFromScreen",
		"screenshotPngBase64 = Capture-WindowPngBase64 $bounds $targetHwnd $IncludeImage",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows screenshot contract missing %q", marker)
		}
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image)") {
		t.Fatal("get_app_state include_image was not forwarded to Build-Snapshot")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-SnapshotForProcess $process $operation.app $null $AccessibilityTreeMaxNodeCount $AccessibilityTreeMaxDepth $true") {
		t.Fatal("action refreshes must retain the validated process and screenshots")
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
	if !strings.Contains(windowsRuntimeScript, "$script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth") {
		t.Fatal("Windows runtime should use shared tree budget constants while rendering")
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
