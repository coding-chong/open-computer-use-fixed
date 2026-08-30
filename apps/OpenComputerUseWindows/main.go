package main

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

var version = "0.3.1"

var clickMethodValues = []string{"auto", "accessibility", "app_post", "sky_click", "global"}

const maxMCPIDLength = 128

//go:embed runtime.ps1
var windowsRuntimeScript string

const serverInstructions = "Computer Use tools let you interact with Windows apps by performing UI actions.\n\nBegin by calling `get_app_state` every turn you want to use Computer Use to get the latest state before acting. The available tools are list_apps, get_app_state, save_screenshot, click, perform_secondary_action, scroll, drag, type_text, press_key, and set_value.\n\nTo inspect or understand visual pixels, call `get_app_state` with `include_image=true`; its image/png result is the model-visible screenshot. Do not use `press_key` to simulate PrintScreen, Win+Shift+S, or another operating-system screenshot shortcut. A successful action already returns a refreshed screenshot when available, so use that result rather than taking a second screenshot. Use `save_screenshot` only when the user asks to save or export a PNG file.\n\nPrefer element-targeted interactions over coordinate clicks when a generation-bound element identifier from the latest `get_app_state` is available; treat the complete identifier as opaque and call `get_app_state` again after any refresh or target change. Windows actions use UI Automation patterns first and fall back to window messages when an app does not expose the needed pattern. Element-targeted coordinate fallback requires a valid finite snapshot frame or explicit finite x/y; semantic UIA actions may work without a frame, but missing coordinate sources fail closed. The Windows runtime does not auto-launch apps, perform SetFocus, or use UIA text fallback by default, so background-capable actions do not intentionally steal the user's foreground focus. Windows `type_text` requires the current focused control to be a writable text field owned by the validated process and snapshot window; click/select the field first, and use `set_value` with the complete generation-bound identifier in `element_index` for exact element targeting. It never searches the current UIA tree for a substitute control or falls back to top-level keyboard messages. Global click and physical drag require both `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1` and `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`; without those flags, drag only uses an app-scoped background window-message path that never moves the system pointer or changes foreground focus and may be unsupported by the target toolkit. `press_key` is rejected unless the foreground-input flag is set, and then requires a target that already owns the foreground window. The runtime only attempts a bounded `SetForegroundWindow` for keyboard input when `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1` is also set; otherwise focus the target with an authorized global click first. These explicit Windows environment authorizations can move the pointer or foreground the target, and input can fail for foreground-policy or elevated/UIPI-protected applications."

type toolDefinition struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Annotations map[string]any `json:"annotations,omitempty"`
	InputSchema map[string]any `json:"inputSchema"`
}

type contentItem struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

type toolCallResult struct {
	Content []contentItem `json:"content"`
	IsError bool          `json:"isError"`
}

func textResult(text string, isError bool) toolCallResult {
	return toolCallResult{Content: []contentItem{{Type: "text", Text: text}}, IsError: isError}
}

type appDescriptor struct {
	Name                  string `json:"name"`
	BundleIdentifier      string `json:"bundleIdentifier,omitempty"`
	PID                   int    `json:"pid"`
	ProcessStartTimeTicks int64  `json:"processStartTimeTicks,omitempty"`
	MainWindowHandle      int64  `json:"mainWindowHandle,omitempty"`
}

type frame struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

func (f frame) renderedLocalFrame() string {
	return fmt.Sprintf("{{x: %.0f, y: %.0f, width: %.0f, height: %.0f}}", f.X, f.Y, f.Width, f.Height)
}

type elementRecord struct {
	Index                int      `json:"index"`
	RuntimeID            []int    `json:"runtimeId,omitempty"`
	AutomationID         string   `json:"automationId,omitempty"`
	Name                 string   `json:"name,omitempty"`
	ControlType          string   `json:"controlType,omitempty"`
	LocalizedControlType string   `json:"localizedControlType,omitempty"`
	ClassName            string   `json:"className,omitempty"`
	Value                string   `json:"value,omitempty"`
	NativeWindowHandle   int64    `json:"nativeWindowHandle,omitempty"`
	Frame                *frame   `json:"frame,omitempty"`
	Actions              []string `json:"actions,omitempty"`
	publicRef            string   `json:"-"`
}

type appSnapshot struct {
	App                 appDescriptor   `json:"app"`
	WindowTitle         string          `json:"windowTitle,omitempty"`
	WindowBounds        *frame          `json:"windowBounds,omitempty"`
	ScreenshotPNGBase64 string          `json:"screenshotPngBase64,omitempty"`
	TreeLines           []string        `json:"treeLines,omitempty"`
	FocusedSummary      string          `json:"focusedSummary,omitempty"`
	SelectedText        string          `json:"selectedText,omitempty"`
	Elements            []elementRecord `json:"elements,omitempty"`
	snapshotToken       string
}

func (s *appSnapshot) renderedTreeLines() []string {
	if s == nil || len(s.TreeLines) == 0 || len(s.Elements) == 0 {
		if s == nil {
			return nil
		}
		return append([]string(nil), s.TreeLines...)
	}
	refsByIndex := make(map[int]string, len(s.Elements))
	for _, record := range s.Elements {
		if record.publicRef != "" {
			refsByIndex[record.Index] = record.publicRef
		}
	}
	if len(refsByIndex) == 0 {
		return append([]string(nil), s.TreeLines...)
	}
	lines := append([]string(nil), s.TreeLines...)
	for lineIndex, line := range lines {
		localIndex, end, ok := leadingTreeLineIndex(line)
		if !ok {
			continue
		}
		ref, exists := refsByIndex[localIndex]
		if !exists {
			continue
		}
		start := end
		for start > 0 && line[start-1] >= '0' && line[start-1] <= '9' {
			start--
		}
		lines[lineIndex] = line[:start] + ref + line[end:]
	}
	return lines
}

func leadingTreeLineIndex(line string) (int, int, bool) {
	start := 0
	for start < len(line) && (line[start] == '\t' || line[start] == ' ') {
		start++
	}
	end := start
	for end < len(line) && line[end] >= '0' && line[end] <= '9' {
		end++
	}
	if end == start {
		return 0, 0, false
	}
	index, err := strconv.Atoi(line[start:end])
	if err != nil {
		return 0, 0, false
	}
	return index, end, true
}

func (s *appSnapshot) renderedText() string {
	if s == nil {
		return ""
	}
	appRef := s.App.BundleIdentifier
	if appRef == "" {
		appRef = s.App.Name
	}
	title := s.WindowTitle
	if strings.TrimSpace(title) == "" {
		title = s.App.Name
	}

	lines := []string{
		fmt.Sprintf("App=%s (pid %d)", appRef, s.App.PID),
		fmt.Sprintf("Window: %q, App: %s.", title, s.App.Name),
	}
	lines = append(lines, s.renderedTreeLines()...)
	if strings.TrimSpace(s.SelectedText) != "" {
		lines = append(lines, "", fmt.Sprintf("Selected text: [%s]", s.SelectedText))
	} else if strings.TrimSpace(s.FocusedSummary) != "" {
		lines = append(lines, "", fmt.Sprintf("The focused UI element is %s.", s.FocusedSummary))
	}
	return strings.Join(lines, "\n")
}

func (s *appSnapshot) result() toolCallResult {
	result := toolCallResult{
		Content: []contentItem{{Type: "text", Text: s.renderedText()}},
	}
	if s != nil && s.ScreenshotPNGBase64 != "" {
		result.Content = append(result.Content, contentItem{
			Type:     "image",
			Data:     s.ScreenshotPNGBase64,
			MimeType: "image/png",
		})
	}
	return result
}

type psRequest struct {
	Tool                     string         `json:"tool"`
	App                      string         `json:"app,omitempty"`
	Element                  *elementRecord `json:"element,omitempty"`
	X                        *float64       `json:"x,omitempty"`
	Y                        *float64       `json:"y,omitempty"`
	FromX                    *float64       `json:"from_x,omitempty"`
	FromY                    *float64       `json:"from_y,omitempty"`
	ToX                      *float64       `json:"to_x,omitempty"`
	ToY                      *float64       `json:"to_y,omitempty"`
	ClickCount               int            `json:"click_count,omitempty"`
	MouseButton              string         `json:"mouse_button,omitempty"`
	ClickMethod              string         `json:"click_method,omitempty"`
	Action                   string         `json:"action,omitempty"`
	Direction                string         `json:"direction,omitempty"`
	Pages                    float64        `json:"pages,omitempty"`
	Text                     string         `json:"text,omitempty"`
	Key                      string         `json:"key,omitempty"`
	Value                    string         `json:"value,omitempty"`
	WindowBounds             *frame         `json:"windowBounds,omitempty"`
	ExpectedPID              int            `json:"expectedPid,omitempty"`
	ExpectedStartTimeTicks   int64          `json:"expectedProcessStartTimeTicks,omitempty"`
	ExpectedMainWindowHandle int64          `json:"expectedMainWindowHandle,omitempty"`
	TextLimit                any            `json:"text_limit,omitempty"`
	MaxTreeNodes             int            `json:"max_tree_nodes,omitempty"`
	MaxTreeDepth             int            `json:"max_tree_depth,omitempty"`
	IncludeImage             bool           `json:"include_image,omitempty"`
}

type textLimit struct {
	max   bool
	count int
}

func (limit textLimit) runtimeValue() any {
	if limit.max {
		return "max"
	}
	return limit.count
}

type psResponse struct {
	OK       bool         `json:"ok"`
	Text     string       `json:"text,omitempty"`
	Error    string       `json:"error,omitempty"`
	Snapshot *appSnapshot `json:"snapshot,omitempty"`
}

const (
	targetChangedMessage  = "Target changed; call get_app_state again."
	maxSnapshotBindings   = 64
	maxAliasTargetsPerKey = 8
	maxAliasKeys          = 256
	snapshotAliasTTL      = 5 * time.Minute
	maxClickCount         = 100
	// Keep the bounded scroll request within the runtime's safe wheel-delta
	// range; semantic delivery performs at most one UIA operation.
	maxScrollPages         = 100
	maxElementIndexDigits  = 10
	maxElementReferenceLen = len("s-0000000000000000:") + maxElementIndexDigits
	maxSafeJSONInteger     = float64(1<<53 - 1)
	maxRuntimeOutputBytes  = 1 << 20
	maxCoordinateMagnitude = float64(1<<30 - 1)

	windowsRuntimeTimeoutMessage = "Windows runtime timed out after 30s"
	windowsScrollTimeoutMessage  = "Windows scroll timed out; refresh with get_app_state before retrying because the operation may have been applied."
)

type snapshotTarget struct {
	pid              int
	startTimeTicks   int64
	mainWindowHandle int64
}

type cachedSnapshot struct {
	snapshot *appSnapshot
	lastSeen time.Time
}

type snapshotBinding struct {
	snapshot *appSnapshot
	target   snapshotTarget
	token    string
}

func targetChangedError() error {
	return errors.New(targetChangedMessage)
}

type service struct {
	stateMu        sync.RWMutex
	actionMu       sync.Mutex
	aliases        map[string]map[snapshotTarget]cachedSnapshot
	aliasLastSeen  map[string]time.Time
	tokenBindings  map[string]*snapshotBinding
	latestTokens   map[snapshotTarget]string
	tokenOrder     []string
	nextGeneration uint64
	now            func() time.Time
}

func newService() *service {
	return &service{
		aliases:       map[string]map[snapshotTarget]cachedSnapshot{},
		aliasLastSeen: map[string]time.Time{},
		tokenBindings: map[string]*snapshotBinding{},
		latestTokens:  map[snapshotTarget]string{},
		now:           time.Now,
	}
}

func parseElementIndexArgument(args map[string]any, required bool) (string, error) {
	raw, present := args["element_index"]
	if !present {
		if required {
			return "", errors.New("Missing required argument: element_index")
		}
		return "", nil
	}
	value, ok := raw.(string)
	if !ok || strings.TrimSpace(value) == "" {
		return "", targetChangedError()
	}
	value = strings.TrimSpace(value)
	if _, _, ok := parseElementReference(value); !ok {
		return "", targetChangedError()
	}
	return value, nil
}

func (s *service) callTool(name string, args map[string]any) toolCallResult {
	switch name {
	case "list_apps":
		return s.listApps()
	case "get_app_state":
		maxTreeNodes, err := optionalPositiveInt(args, "max_tree_nodes")
		if err != nil {
			return textResult(err.Error(), true)
		}
		maxTreeDepth, err := optionalPositiveInt(args, "max_tree_depth")
		if err != nil {
			return textResult(err.Error(), true)
		}
		textLimit, err := optionalTextLimit(args, "text_limit")
		if err != nil {
			return textResult(err.Error(), true)
		}
		includeImage, err := optionalBool(args, "include_image")
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.getAppState(requiredString(args, "app"), textLimit, maxTreeNodes, maxTreeDepth, includeImage)
	case "save_screenshot":
		return s.saveScreenshot(requiredString(args, "app"), requiredString(args, "path"))
	case "click":
		elementIndex, err := parseElementIndexArgument(args, false)
		if err != nil {
			return textResult(err.Error(), true)
		}
		x, err := optionalCoordinate(args, "x")
		if err != nil {
			return textResult(err.Error(), true)
		}
		y, err := optionalCoordinate(args, "y")
		if err != nil {
			return textResult(err.Error(), true)
		}
		clickCount, err := optionalClickCount(args, "click_count")
		if err != nil {
			return textResult(err.Error(), true)
		}
		clickMethodValue, err := optionalEnumString(args, "click_method")
		if err != nil {
			return textResult(err.Error(), true)
		}
		clickMethod, err := parseClickMethod(clickMethodValue)
		if err != nil {
			return textResult(err.Error(), true)
		}
		mouseButton, err := optionalEnumString(args, "mouse_button")
		if err != nil {
			return textResult(err.Error(), true)
		}
		mouseButton, err = parseMouseButton(mouseButton)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.click(
			requiredString(args, "app"),
			elementIndex,
			x,
			y,
			clickCount,
			mouseButton,
			clickMethod,
		)
	case "perform_secondary_action":
		elementIndex, err := parseElementIndexArgument(args, true)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.performSecondaryAction(
			requiredString(args, "app"),
			elementIndex,
			requiredString(args, "action"),
		)
	case "scroll":
		elementIndex, err := parseElementIndexArgument(args, true)
		if err != nil {
			return textResult(err.Error(), true)
		}
		pages, err := optionalScrollPages(args, "pages")
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.scroll(
			requiredString(args, "app"),
			requiredString(args, "direction"),
			elementIndex,
			pages,
		)
	case "drag":
		fromX, err := requiredCoordinate(args, "from_x")
		if err != nil {
			return textResult(err.Error(), true)
		}
		fromY, err := requiredCoordinate(args, "from_y")
		if err != nil {
			return textResult(err.Error(), true)
		}
		toX, err := requiredCoordinate(args, "to_x")
		if err != nil {
			return textResult(err.Error(), true)
		}
		toY, err := requiredCoordinate(args, "to_y")
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.drag(
			requiredString(args, "app"),
			fromX,
			fromY,
			toX,
			toY,
		)
	case "type_text":
		return s.typeText(requiredString(args, "app"), requiredString(args, "text"))
	case "press_key":
		return s.pressKey(requiredString(args, "app"), requiredString(args, "key"))
	case "set_value":
		elementIndex, err := parseElementIndexArgument(args, true)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.setValue(requiredString(args, "app"), elementIndex, requiredString(args, "value"))
	default:
		return textResult("Unsupported tool.", true)
	}
}

func (s *service) listApps() toolCallResult {
	response, err := runPowerShell(psRequest{Tool: "list_apps"})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(response.Error, true)
	}
	if strings.TrimSpace(response.Text) == "" {
		response.Text = "No running top-level apps are visible to this Windows runtime."
	}
	return textResult(response.Text, false)
}

func (s *service) getAppState(app string, textLimit *textLimit, maxTreeNodes, maxTreeDepth *int, includeImage bool) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	request := psRequest{Tool: "get_app_state", App: app, IncludeImage: includeImage}
	if textLimit != nil {
		request.TextLimit = textLimit.runtimeValue()
	}
	if maxTreeNodes != nil {
		request.MaxTreeNodes = *maxTreeNodes
	}
	if maxTreeDepth != nil {
		request.MaxTreeDepth = *maxTreeDepth
	}
	snapshot, result := s.refreshSnapshot(app, request)
	if result.IsError {
		return result
	}
	return snapshot.result()
}

func (s *service) saveScreenshot(app, path string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if path == "" {
		return textResult("Missing required argument: path", true)
	}
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return textResult("save_screenshot path must be absolute", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return s.snapshotActionError(app)
	}
	request, err := bindSnapshotTarget(snapshot, psRequest{Tool: "get_app_state", App: app, IncludeImage: true})
	if err != nil {
		return textResult(err.Error(), true)
	}
	snapshot, result := s.refreshSnapshot(app, request)
	if result.IsError {
		return result
	}
	if snapshot.ScreenshotPNGBase64 == "" {
		return textResult("Windows runtime did not return screenshot image data.", true)
	}
	data, err := base64.StdEncoding.DecodeString(snapshot.ScreenshotPNGBase64)
	if err != nil {
		return textResult("Invalid screenshot image data.", true)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return textResult("Unable to save screenshot file.", true)
	}
	return textResult(fmt.Sprintf("Screenshot saved to %s (%d bytes).", path, len(data)), false)
}

func (s *service) click(app, elementIndex string, x, y *float64, clickCount int, mouseButton, clickMethod string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if clickCount < 1 || clickCount > maxClickCount {
		return textResult(fmt.Sprintf("click_count must be an integer between 1 and %d", maxClickCount), true)
	}
	if err := validateCoordinatePointer(x, "x"); err != nil {
		return textResult(err.Error(), true)
	}
	if err := validateCoordinatePointer(y, "y"); err != nil {
		return textResult(err.Error(), true)
	}
	if elementIndex == "" && (x == nil || y == nil) {
		return textResult("click requires either element_index or x/y", true)
	}
	if clickMethod == "accessibility" && elementIndex == "" {
		return textResult("click_method 'accessibility' requires element_index", true)
	}
	if clickMethod == "sky_click" {
		return textResult("click_method 'sky_click' is not supported on Windows", true)
	}
	var snapshot *appSnapshot
	var record *elementRecord
	if elementIndex != "" {
		var err error
		snapshot, record, err = s.lookupElementForApp(app, elementIndex)
		if err != nil {
			return textResult(err.Error(), true)
		}
	} else {
		snapshot = s.currentSnapshot(app)
		if snapshot == nil {
			return s.snapshotActionError(app)
		}
	}
	request := psRequest{
		Tool:         "click",
		App:          app,
		X:            x,
		Y:            y,
		ClickCount:   clickCount,
		MouseButton:  mouseButton,
		ClickMethod:  clickMethod,
		WindowBounds: snapshot.WindowBounds,
	}
	if record != nil {
		request.Element = record
	}
	return s.actionResult(app, snapshot, request)
}

func (s *service) performSecondaryAction(app, elementIndex, action string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	if action == "" {
		return textResult("Missing required argument: action", true)
	}
	snapshot, record, err := s.lookupElementForApp(app, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "perform_secondary_action", App: app, Element: record, Action: action})
}

func (s *service) scroll(app, direction, elementIndex string, pages float64) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	normalized := strings.ToLower(direction)
	if normalized != "up" && normalized != "down" && normalized != "left" && normalized != "right" {
		return textResult("Invalid scroll direction.", true)
	}
	validatedPages, err := validateScrollPages(pages, "pages")
	if err != nil {
		return textResult(err.Error(), true)
	}
	snapshot, record, err := s.lookupElementForApp(app, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "scroll", App: app, Element: record, Direction: normalized, Pages: validatedPages, WindowBounds: snapshot.WindowBounds})
}

func (s *service) drag(app string, fromX, fromY, toX, toY *float64) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if fromX == nil {
		return textResult("Missing required argument: from_x", true)
	}
	if fromY == nil {
		return textResult("Missing required argument: from_y", true)
	}
	if toX == nil {
		return textResult("Missing required argument: to_x", true)
	}
	if toY == nil {
		return textResult("Missing required argument: to_y", true)
	}
	for _, coordinate := range []struct {
		value *float64
		key   string
	}{
		{fromX, "from_x"},
		{fromY, "from_y"},
		{toX, "to_x"},
		{toY, "to_y"},
	} {
		if err := validateCoordinatePointer(coordinate.value, coordinate.key); err != nil {
			return textResult(err.Error(), true)
		}
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return s.snapshotActionError(app)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "drag", App: app, FromX: fromX, FromY: fromY, ToX: toX, ToY: toY, WindowBounds: snapshot.WindowBounds})
}

func (s *service) typeText(app, text string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if text == "" {
		return textResult("Missing required argument: text", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return s.snapshotActionError(app)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "type_text", App: app, Text: text})
}

func (s *service) pressKey(app, key string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if key == "" {
		return textResult("Missing required argument: key", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return s.snapshotActionError(app)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "press_key", App: app, Key: key})
}

func (s *service) setValue(app, elementIndex, value string) toolCallResult {
	s.actionMu.Lock()
	defer s.actionMu.Unlock()
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	snapshot, record, err := s.lookupElementForApp(app, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, snapshot, psRequest{Tool: "set_value", App: app, Element: record, Value: value})
}

func bindSnapshotTarget(snapshot *appSnapshot, request psRequest) (psRequest, error) {
	if snapshot == nil || snapshot.App.PID <= 0 || snapshot.App.ProcessStartTimeTicks <= 0 || snapshot.App.MainWindowHandle == 0 {
		return psRequest{}, errors.New("No stable target identity is available. Run get_app_state again.")
	}
	request.ExpectedPID = snapshot.App.PID
	request.ExpectedStartTimeTicks = snapshot.App.ProcessStartTimeTicks
	request.ExpectedMainWindowHandle = snapshot.App.MainWindowHandle
	if request.WindowBounds == nil {
		request.WindowBounds = snapshot.WindowBounds
	}
	return request, nil
}

func (s *service) actionResult(app string, snapshot *appSnapshot, request psRequest) toolCallResult {
	if !s.isCurrentSnapshot(snapshot) {
		return textResult(targetChangedMessage, true)
	}
	request, err := bindSnapshotTarget(snapshot, request)
	if err != nil {
		return textResult(err.Error(), true)
	}
	request.App = app
	request.IncludeImage = true
	refreshed, result := s.refreshSnapshot(app, request)
	if result.IsError {
		return result
	}
	return refreshed.result()
}

func (s *service) refreshSnapshot(app string, request psRequest) (*appSnapshot, toolCallResult) {
	response, err := runPowerShell(request)
	if err != nil {
		return nil, textResult(err.Error(), true)
	}
	if !response.OK {
		return nil, textResult(response.Error, true)
	}
	if response.Snapshot == nil {
		return nil, textResult("Windows runtime did not return an app snapshot.", true)
	}
	if _, ok := snapshotTargetFromSnapshot(response.Snapshot); !ok {
		return nil, textResult("Windows runtime did not return a stable app snapshot.", true)
	}
	if !validSnapshotForPublication(response.Snapshot) {
		return nil, textResult("Windows runtime returned an invalid app snapshot.", true)
	}
	published := s.rememberSnapshot(app, response.Snapshot)
	if published == nil {
		return nil, textResult("Windows runtime did not return a stable app snapshot.", true)
	}
	return published, toolCallResult{}
}

func snapshotCacheKey(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func snapshotTargetFromSnapshot(snapshot *appSnapshot) (snapshotTarget, bool) {
	if snapshot == nil || snapshot.App.PID <= 0 || snapshot.App.ProcessStartTimeTicks <= 0 || snapshot.App.MainWindowHandle == 0 {
		return snapshotTarget{}, false
	}
	return snapshotTarget{
		pid:              snapshot.App.PID,
		startTimeTicks:   snapshot.App.ProcessStartTimeTicks,
		mainWindowHandle: snapshot.App.MainWindowHandle,
	}, true
}

func validSnapshotForPublication(snapshot *appSnapshot) bool {
	if _, ok := snapshotTargetFromSnapshot(snapshot); !ok {
		return false
	}
	seenIndexes := make(map[int]struct{}, len(snapshot.Elements))
	for _, record := range snapshot.Elements {
		if record.Index < 0 {
			return false
		}
		if _, exists := seenIndexes[record.Index]; exists {
			return false
		}
		seenIndexes[record.Index] = struct{}{}
	}
	return true
}

func sameSnapshotTarget(left, right *appSnapshot) bool {
	leftTarget, leftOK := snapshotTargetFromSnapshot(left)
	rightTarget, rightOK := snapshotTargetFromSnapshot(right)
	return leftOK && rightOK && leftTarget == rightTarget
}

func (s *service) currentTime() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

func snapshotAliasKeys(query string, snapshot *appSnapshot) []string {
	rawKeys := []string{query, snapshot.WindowTitle, snapshot.App.Name, snapshot.App.BundleIdentifier, strconv.Itoa(snapshot.App.PID)}
	keys := make([]string, 0, len(rawKeys))
	seen := map[string]bool{}
	for _, rawKey := range rawKeys {
		key := snapshotCacheKey(rawKey)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		keys = append(keys, key)
	}
	return keys
}

func (s *service) removeTokenLocked(token string) {
	if token == "" {
		return
	}
	binding := s.tokenBindings[token]
	delete(s.tokenBindings, token)
	if binding != nil && s.latestTokens[binding.target] == token {
		delete(s.latestTokens, binding.target)
	}
	for index, candidate := range s.tokenOrder {
		if candidate != token {
			continue
		}
		copy(s.tokenOrder[index:], s.tokenOrder[index+1:])
		s.tokenOrder = s.tokenOrder[:len(s.tokenOrder)-1]
		break
	}
}

func (s *service) publishSnapshotLocked(snapshot *appSnapshot, target snapshotTarget) {
	s.nextGeneration++
	snapshot.snapshotToken = fmt.Sprintf("s-%016x", s.nextGeneration)
	for index := range snapshot.Elements {
		snapshot.Elements[index].publicRef = fmt.Sprintf("%s:%d", snapshot.snapshotToken, snapshot.Elements[index].Index)
	}

	if previous := s.latestTokens[target]; previous != "" && previous != snapshot.snapshotToken {
		s.removeTokenLocked(previous)
	}
	if s.tokenBindings[snapshot.snapshotToken] == nil {
		s.tokenOrder = append(s.tokenOrder, snapshot.snapshotToken)
	}
	s.tokenBindings[snapshot.snapshotToken] = &snapshotBinding{
		snapshot: snapshot,
		target:   target,
		token:    snapshot.snapshotToken,
	}
	s.latestTokens[target] = snapshot.snapshotToken
	for len(s.tokenOrder) > maxSnapshotBindings {
		s.removeTokenLocked(s.tokenOrder[0])
	}
}

func snapshotTargetLess(left, right snapshotTarget) bool {
	if left.pid != right.pid {
		return left.pid < right.pid
	}
	if left.startTimeTicks != right.startTimeTicks {
		return left.startTimeTicks < right.startTimeTicks
	}
	return left.mainWindowHandle < right.mainWindowHandle
}
func pruneAliasEntries(entries map[snapshotTarget]cachedSnapshot, now time.Time) {
	for target, cached := range entries {
		if now.Sub(cached.lastSeen) > snapshotAliasTTL {
			delete(entries, target)
		}
	}
	for len(entries) > maxAliasTargetsPerKey {
		var oldestTarget snapshotTarget
		var oldestTime time.Time
		first := true
		for target, cached := range entries {
			if first || cached.lastSeen.Before(oldestTime) || (cached.lastSeen.Equal(oldestTime) && snapshotTargetLess(target, oldestTarget)) {
				oldestTarget = target
				oldestTime = cached.lastSeen
				first = false
			}
		}
		if first {
			break
		}
		delete(entries, oldestTarget)
	}
}

func (s *service) removeAliasLocked(key string) {
	delete(s.aliases, key)
	delete(s.aliasLastSeen, key)
}

func (s *service) pruneAliasesLocked(now time.Time) {
	for key, entries := range s.aliases {
		for target, cached := range entries {
			if cached.snapshot == nil || cached.snapshot.snapshotToken == "" {
				delete(entries, target)
				continue
			}
			binding := s.tokenBindings[cached.snapshot.snapshotToken]
			if binding == nil || binding.snapshot != cached.snapshot || binding.target != target {
				delete(entries, target)
			}
		}
		pruneAliasEntries(entries, now)
		if len(entries) == 0 {
			s.removeAliasLocked(key)
			continue
		}
		lastSeen := s.aliasLastSeen[key]
		if lastSeen.IsZero() || now.Sub(lastSeen) > snapshotAliasTTL {
			latest := lastSeen
			for _, cached := range entries {
				if latest.IsZero() || cached.lastSeen.After(latest) {
					latest = cached.lastSeen
				}
			}
			if !latest.IsZero() && now.Sub(latest) > snapshotAliasTTL {
				s.removeAliasLocked(key)
				continue
			}
			s.aliasLastSeen[key] = latest
		}
	}
	for len(s.aliases) > maxAliasKeys {
		oldestKey := ""
		var oldest time.Time
		for key := range s.aliases {
			seen := s.aliasLastSeen[key]
			if oldestKey == "" || seen.Before(oldest) || (seen.Equal(oldest) && key < oldestKey) {
				oldestKey = key
				oldest = seen
			}
		}
		if oldestKey == "" {
			break
		}
		s.removeAliasLocked(oldestKey)
	}
}

func (s *service) touchAliasLocked(key string, now time.Time) {
	s.aliasLastSeen[key] = now
}

func cloneFrame(value *frame) *frame {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneElementRecord(record elementRecord) elementRecord {
	copy := record
	copy.RuntimeID = append([]int(nil), record.RuntimeID...)
	copy.Actions = append([]string(nil), record.Actions...)
	copy.Frame = cloneFrame(record.Frame)
	return copy
}

func cloneSnapshot(snapshot *appSnapshot) *appSnapshot {
	if snapshot == nil {
		return nil
	}
	copy := *snapshot
	copy.WindowBounds = cloneFrame(snapshot.WindowBounds)
	copy.TreeLines = append([]string(nil), snapshot.TreeLines...)
	copy.Elements = make([]elementRecord, len(snapshot.Elements))
	for index, record := range snapshot.Elements {
		copy.Elements[index] = cloneElementRecord(record)
	}
	return &copy
}

func (s *service) rememberSnapshot(query string, snapshot *appSnapshot) *appSnapshot {
	if !validSnapshotForPublication(snapshot) {
		return nil
	}
	target, _ := snapshotTargetFromSnapshot(snapshot)
	published := cloneSnapshot(snapshot)
	now := s.currentTime()
	s.stateMu.Lock()
	defer s.stateMu.Unlock()

	s.pruneAliasesLocked(now)
	s.publishSnapshotLocked(published, target)
	for _, entries := range s.aliases {
		if _, exists := entries[target]; !exists {
			continue
		}
		entries[target] = cachedSnapshot{snapshot: published, lastSeen: entries[target].lastSeen}
	}
	for _, key := range snapshotAliasKeys(query, published) {
		entries := s.aliases[key]
		if entries == nil {
			entries = map[snapshotTarget]cachedSnapshot{}
			s.aliases[key] = entries
		}
		pruneAliasEntries(entries, now)
		entries[target] = cachedSnapshot{snapshot: published, lastSeen: now}
		s.touchAliasLocked(key, now)
		pruneAliasEntries(entries, now)
	}
	s.pruneAliasesLocked(now)
	return published
}

func (s *service) aliasSnapshotLocked(app string, now time.Time) (*appSnapshot, bool, bool) {
	key := snapshotCacheKey(app)
	if key == "" {
		return nil, false, false
	}
	entries := s.aliases[key]
	if len(entries) == 0 {
		return nil, false, false
	}
	for target, cached := range entries {
		if cached.snapshot == nil || cached.snapshot.snapshotToken == "" {
			delete(entries, target)
			continue
		}
		binding := s.tokenBindings[cached.snapshot.snapshotToken]
		if binding == nil || binding.snapshot != cached.snapshot || binding.target != target || s.latestTokens[target] != cached.snapshot.snapshotToken {
			delete(entries, target)
		}
	}
	pruneAliasEntries(entries, now)
	if len(entries) == 0 {
		s.removeAliasLocked(key)
		return nil, false, false
	}
	s.touchAliasLocked(key, now)
	if len(entries) > 1 {
		return nil, true, true
	}
	for _, cached := range entries {
		return cached.snapshot, false, true
	}
	return nil, false, false
}

func (s *service) currentSnapshot(app string) *appSnapshot {
	now := s.currentTime()
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	snapshot, _, _ := s.aliasSnapshotLocked(app, now)
	return snapshot
}

func (s *service) snapshotIsAmbiguous(app string) bool {
	now := s.currentTime()
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	_, ambiguous, found := s.aliasSnapshotLocked(app, now)
	return found && ambiguous
}

func (s *service) snapshotActionError(app string) toolCallResult {
	if s.snapshotIsAmbiguous(app) {
		return textResult("App selector matches multiple cached targets. Run get_app_state with an exact window title or PID before action tools.", true)
	}
	return textResult("No app state is available. Run get_app_state before action tools.", true)
}

func (s *service) isCurrentSnapshot(snapshot *appSnapshot) bool {
	target, ok := snapshotTargetFromSnapshot(snapshot)
	if !ok || snapshot.snapshotToken == "" {
		return false
	}
	s.stateMu.RLock()
	defer s.stateMu.RUnlock()
	latest := s.latestTokens[target]
	binding := s.tokenBindings[latest]
	return latest == snapshot.snapshotToken && binding != nil && binding.snapshot == snapshot
}

func (s *service) lookupElementForApp(app, elementRef string) (*appSnapshot, *elementRecord, error) {
	prefix, index, ok := parseElementReference(elementRef)
	if !ok {
		return nil, nil, targetChangedError()
	}
	now := s.currentTime()
	s.stateMu.Lock()
	defer s.stateMu.Unlock()

	binding := s.tokenBindings[prefix]
	current, ambiguous, found := s.aliasSnapshotLocked(app, now)
	currentTarget, currentTargetOK := snapshotTargetFromSnapshot(current)
	if !found || ambiguous || binding == nil || current == nil || current != binding.snapshot || !currentTargetOK || currentTarget != binding.target || s.latestTokens[binding.target] != prefix {
		return nil, nil, targetChangedError()
	}
	for _, record := range binding.snapshot.Elements {
		if record.Index != index || record.publicRef != strings.TrimSpace(elementRef) {
			continue
		}
		copy := record
		return binding.snapshot, &copy, nil
	}
	return nil, nil, targetChangedError()
}

func parseElementReference(value string) (string, int, bool) {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > maxElementReferenceLen {
		return "", 0, false
	}
	prefix, suffix, ok := strings.Cut(value, ":")
	if !ok || len(prefix) != len("s-")+16 || !strings.HasPrefix(prefix, "s-") || suffix == "" || len(suffix) > maxElementIndexDigits {
		return "", 0, false
	}
	if len(suffix) > 1 && suffix[0] == '0' {
		return "", 0, false
	}
	for index := 0; index < len(suffix); index++ {
		if suffix[index] < '0' || suffix[index] > '9' {
			return "", 0, false
		}
	}
	generation, err := strconv.ParseUint(strings.TrimPrefix(prefix, "s-"), 16, 64)
	if err != nil || generation == 0 {
		return "", 0, false
	}
	index, err := strconv.Atoi(suffix)
	if err != nil || index < 0 {
		return "", 0, false
	}
	return prefix, index, true
}

func lookupElement(snapshot *appSnapshot, elementRef string) (*elementRecord, error) {
	prefix, index, ok := parseElementReference(elementRef)
	if !ok || snapshot == nil || snapshot.snapshotToken != prefix {
		return nil, targetChangedError()
	}
	for _, record := range snapshot.Elements {
		if record.Index != index || record.publicRef != strings.TrimSpace(elementRef) {
			continue
		}
		copy := record
		return &copy, nil
	}
	return nil, targetChangedError()
}

type boundedOutput struct {
	data      []byte
	limit     int
	truncated bool
}

func (output *boundedOutput) Write(data []byte) (int, error) {
	remaining := output.limit - len(output.data)
	if remaining > 0 {
		if len(data) > remaining {
			output.data = append(output.data, data[:remaining]...)
			output.truncated = true
		} else {
			output.data = append(output.data, data...)
		}
	} else if len(data) > 0 {
		output.truncated = true
	}
	return len(data), nil
}

func (output *boundedOutput) Bytes() []byte {
	return output.data
}

func (output *boundedOutput) Truncated() bool {
	return output.truncated
}

func runtimeTimeoutError(request psRequest) error {
	if request.Tool == "scroll" {
		return errors.New(windowsScrollTimeoutMessage)
	}
	return errors.New(windowsRuntimeTimeoutMessage)
}

func runPowerShell(request psRequest) (*psResponse, error) {
	if runtime.GOOS != "windows" {
		return nil, errors.New("Windows Computer Use runtime requires powershell.exe on Windows")
	}

	tempDir, err := os.MkdirTemp("", "open-computer-use-windows-*")
	if err != nil {
		return nil, errors.New("Windows runtime could not prepare operation.")
	}
	defer os.RemoveAll(tempDir)

	scriptPath := filepath.Join(tempDir, "runtime.ps1")
	operationPath := filepath.Join(tempDir, "operation.json")
	if err := os.WriteFile(scriptPath, []byte(windowsRuntimeScript), 0o600); err != nil {
		return nil, errors.New("Windows runtime could not prepare operation.")
	}
	operationData, err := json.Marshal(request)
	if err != nil {
		return nil, errors.New("Windows runtime could not encode operation.")
	}
	if err := os.WriteFile(operationPath, operationData, 0o600); err != nil {
		return nil, errors.New("Windows runtime could not prepare operation.")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, operationPath)
	stdout := &boundedOutput{limit: maxRuntimeOutputBytes}
	stderr := &boundedOutput{limit: maxRuntimeOutputBytes}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, runtimeTimeoutError(request)
	}
	if err != nil {
		return nil, errors.New("Windows runtime failed.")
	}
	if stdout.Truncated() || stderr.Truncated() {
		return nil, errors.New("Windows runtime returned oversized output.")
	}

	var response psResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		return nil, errors.New("Windows runtime returned invalid JSON.")
	}
	if !response.OK {
		response.Error = boundedRuntimeError(response.Error)
	}
	return &response, nil
}

func boundedRuntimeError(message string) string {
	message = strings.TrimSpace(message)
	const generic = "Windows runtime operation failed."
	if message == "" || len(message) > 512 || strings.ContainsAny(message, "\r\n") {
		return generic
	}
	if strings.Contains(message, "ScriptStackTrace") || strings.Contains(message, "runtime.ps1") || strings.Contains(message, "operation.json") {
		return generic
	}
	known := map[string]struct{}{
		targetChangedMessage: {},
		"Click requires an element with a valid frame or explicit finite x/y coordinates.":                                                                                                                                                                           {},
		"Scroll requires an element with a valid frame when ScrollPattern is unavailable.":                                                                                                                                                                           {},
		"type_text requires a focused writable text control owned by the requested app/window; click/select the field first or use set_value with the complete generation-bound identifier in element_index.":                                                        {},
		"The focused text control has no usable native edit handle; UIA ValuePattern text fallback is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 or use set_value with the complete generation-bound identifier in element_index.": {},
		"type_text could not write to the focused text control; click/select the field again or use set_value with the complete generation-bound identifier in element_index.":                                                                                       {},
		"Interactive Windows input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 to enable it.":                                                                                                                                     {},
		"Global pointer input is disabled by default; set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to enable it.":                                                                                                                                          {},
		"Interactive Windows keyboard input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 and focus the target before sending a key.":                                                                                               {},
		"SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it.":                                                                                                                            {},
		"The requested app no longer owns a valid top-level window.":                                                                                                                                                                                                 {},
		"The requested app is not the topmost descendant of the snapshot window at the requested pointer coordinates; interactive input was not sent.":                                                                                                               {},
		"Interactive drag requires at least one movement step.":                                                                                                                                                                                                      {},
		"The requested app is not foreground; focus it with an authorized global click or set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to permit a bounded foreground attempt.":                                                                               {},
		"Windows rejected the bounded foreground request for interactive keyboard input; first focus the target with an authorized global click or use a non-elevated target.":                                                                                       {},
		"Windows could not foreground the requested app for interactive keyboard input; first focus it with an authorized global click or use a non-elevated target.":                                                                                                {},
		"Windows could not convert the requested app-scoped coordinates.":                                                                                                                                                                                            {},
		"Windows did not report a usable virtual desktop for global pointer input.":                                                                                                                                                                                  {},
		"Global pointer coordinates are outside the virtual desktop.":                                                                                                                                                                                                {},
		"Windows could not queue the requested native button click message.":                                                                                                                                                                                         {},
		"Windows could not queue the requested mouse move message.":                                                                                                                                                                                                  {},
		"Windows could not queue the requested mouse-down message.":                                                                                                                                                                                                  {},
		"Windows could not queue the requested mouse-up message.":                                                                                                                                                                                                    {},
		"Windows could not queue the requested background drag move message.":                                                                                                                                                                                        {},
		"Windows could not queue the requested background drag mouse-down message.":                                                                                                                                                                                  {},
		"Windows could not queue the requested background drag mouse-up message.":                                                                                                                                                                                    {},
		"Windows could not queue the requested app-scoped scroll message.":                                                                                                                                                                                           {},
		"Windows semantic scroll operation failed; refresh with get_app_state before retrying because the operation may have been applied.":                                                                                                                          {},
		"The requested secondary action is not supported by this element.":                                                                                                                                                                                           {},
		"click_method 'app_post' requires a native HWND target for this WPF element; use click_method 'global' with the explicit interactive-input configuration.":                                                                                                   {},
		"click_method 'app_post' cannot target WPF coordinate input without a native child HWND; use click_method 'global' with the explicit interactive-input configuration.":                                                                                       {},
		"Windows could not convert the requested app-post coordinates.":                                                                                                                                                                                              {},
		"click_method 'accessibility' requires element_index":                                                                                                                                                                                                        {},
		"click_method 'accessibility' could not click the requested element":                                                                                                                                                                                         {},
		"click_method 'sky_click' is not supported on Windows":                                                                                                                                                                                                       {},
		"Cannot set a value for an element that is not settable":                                                                                                                                                                                                     {},
		"Windows runtime did not return an app snapshot.":                                                                                                                                                                                                            {},
		"Windows runtime did not return a stable app snapshot.":                                                                                                                                                                                                      {},
		"Windows runtime did not return screenshot image data.":                                                                                                                                                                                                      {},
		"Unable to read operation input.":                                                       {},
		"Invalid operation JSON.":                                                               {},
		"Operation JSON must be an object.":                                                     {},
		"Operation JSON requires a non-empty tool.":                                             {},
		"click_count must be an integer between 1 and 100.":                                     {},
		"pages must be finite and in (0,100].":                                                  {},
		"Windows interactive input was rejected or partially accepted; no retry was attempted.": {},
		"Unsupported mouse button.":                                                             {},
		"Unsupported key.":                                                                      {},
		"Unsupported keyboard modifier.":                                                        {},
		"The requested app was not found.":                                                      {},
		"No top-level UI Automation window is available for the requested app.":                 {},
		"Invalid click method.":                                                                 {},
		"Unsupported Windows runtime tool.":                                                     {},
		"Invalid coordinate.":                                                                   {},
		"Missing required drag coordinate.":                                                     {},
		"Accessibility click does not support the requested mouse button.":                      {},
		"Invalid scroll direction.":                                                             {},
		"Click coordinates x and y must be provided together.":                                  {},
		generic: {},
	}
	if _, ok := known[message]; ok {
		return message
	}
	if strings.HasPrefix(message, "Windows accepted ") {
		return "Windows interactive input was rejected or partially accepted; no retry was attempted."
	}
	if strings.HasPrefix(message, "Unsupported mouse button:") {
		return "Unsupported mouse button."
	}
	if strings.HasPrefix(message, "Unsupported key:") {
		return "Unsupported key."
	}
	if strings.HasPrefix(message, "Unsupported modifier:") {
		return "Unsupported keyboard modifier."
	}
	if strings.HasPrefix(message, "appNotFound(") {
		return "The requested app was not found."
	}
	if strings.HasPrefix(message, "No top-level UI Automation window is available") {
		return "No top-level UI Automation window is available for the requested app."
	}
	if strings.HasPrefix(message, "Invalid click_method ") {
		return "Invalid click method."
	}
	if strings.HasPrefix(message, "unsupportedTool(") {
		return "Unsupported Windows runtime tool."
	}
	if strings.HasSuffix(message, " must be a finite coordinate.") || strings.HasSuffix(message, " must be within the supported coordinate range.") {
		return "Invalid coordinate."
	}
	if strings.HasPrefix(message, "Missing required argument: from_") {
		return "Missing required drag coordinate."
	}
	return generic
}

func requiredString(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return strings.TrimSpace(value)
}

func optionalEnumString(args map[string]any, key string) (string, error) {
	value, ok := args[key]
	if !ok {
		return "", nil
	}
	stringValue, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s must be a string", key)
	}
	return stringValue, nil
}

func optionalCoordinate(args map[string]any, key string) (*float64, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	coordinate, err := coordinateFromValue(value, key)
	if err != nil {
		return nil, err
	}
	return &coordinate, nil
}

func requiredCoordinate(args map[string]any, key string) (*float64, error) {
	value, ok := args[key]
	if !ok {
		return nil, fmt.Errorf("Missing required argument: %s", key)
	}
	coordinate, err := coordinateFromValue(value, key)
	if err != nil {
		return nil, err
	}
	return &coordinate, nil
}

func optionalClickCount(args map[string]any, key string) (int, error) {
	value, ok := args[key]
	if !ok {
		return 1, nil
	}
	integer, err := positiveIntFromValue(value, key)
	if err != nil || *integer > maxClickCount {
		return 0, fmt.Errorf("%s must be an integer between 1 and %d", key, maxClickCount)
	}
	return *integer, nil
}

func validateScrollPages(pages float64, key string) (float64, error) {
	if pages <= 0 || pages > maxScrollPages || math.IsNaN(pages) || math.IsInf(pages, 0) {
		return 0, fmt.Errorf("%s must be finite and in (0,%d]", key, maxScrollPages)
	}
	return pages, nil
}

func optionalScrollPages(args map[string]any, key string) (float64, error) {
	value, ok := args[key]
	if !ok {
		return 1, nil
	}
	pages, err := finiteNumberFromValue(value, key)
	if err != nil {
		return 0, fmt.Errorf("%s must be finite and in (0,%d]", key, maxScrollPages)
	}
	return validateScrollPages(pages, key)
}

func validateCoordinatePointer(value *float64, key string) error {
	if value == nil {
		return nil
	}
	_, err := coordinateFromValue(*value, key)
	return err
}

func coordinateFromValue(value any, key string) (float64, error) {
	coordinate, err := finiteNumberFromValue(value, key)
	if err != nil || math.Abs(coordinate) > maxCoordinateMagnitude {
		return 0, fmt.Errorf("%s must be a finite coordinate within +/-%.0f", key, maxCoordinateMagnitude)
	}
	return coordinate, nil
}

func finiteNumberFromValue(value any, key string) (float64, error) {
	var number float64
	switch typed := value.(type) {
	case float64:
		number = typed
	case float32:
		number = float64(typed)
	case json.Number:
		parsed, err := typed.Float64()
		if err != nil {
			return 0, fmt.Errorf("%s must be a finite number", key)
		}
		number = parsed
	case int:
		number = float64(typed)
	case int8:
		number = float64(typed)
	case int16:
		number = float64(typed)
	case int32:
		number = float64(typed)
	case int64:
		number = float64(typed)
	case uint:
		number = float64(typed)
	case uint8:
		number = float64(typed)
	case uint16:
		number = float64(typed)
	case uint32:
		number = float64(typed)
	case uint64:
		number = float64(typed)
	default:
		return 0, fmt.Errorf("%s must be a finite number", key)
	}
	if math.IsNaN(number) || math.IsInf(number, 0) {
		return 0, fmt.Errorf("%s must be a finite number", key)
	}
	return number, nil
}

func positiveIntFromValue(value any, key string) (*int, error) {
	number, err := finiteNumberFromValue(value, key)
	maxInteger := maxSafeJSONInteger
	if float64(maxInt()) < maxInteger {
		maxInteger = float64(maxInt())
	}
	if err != nil || !isWholeNumber(number) || number <= 0 || number > maxInteger {
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
	integer := int(number)
	return &integer, nil
}

func isWholeNumber(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && math.Trunc(value) == value
}

func maxInt() int {
	return int(^uint(0) >> 1)
}

func optionalBool(args map[string]any, key string) (bool, error) {
	value, ok := args[key]
	if !ok {
		return false, nil
	}
	switch typed := value.(type) {
	case bool:
		return typed, nil
	default:
		return false, fmt.Errorf("%s must be a boolean", key)
	}
}

func optionalTextLimit(args map[string]any, key string) (*textLimit, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return textLimitFromValue(value, key)
}

func textLimitFromValue(value any, key string) (*textLimit, error) {
	if stringValue, ok := value.(string); ok {
		if strings.EqualFold(stringValue, "max") {
			return &textLimit{max: true}, nil
		}
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	integer, err := positiveIntFromValue(value, key)
	if err != nil {
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	return &textLimit{count: *integer}, nil
}

func optionalPositiveInt(args map[string]any, key string) (*int, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return positiveIntFromValue(value, key)
}

func defaultString(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func parseMouseButton(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "left", nil
	}
	for _, candidate := range []string{"left", "right", "middle"} {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", errors.New("Unsupported mouse button.")
}

func parseClickMethod(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "auto", nil
	}
	for _, candidate := range clickMethodValues {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", errors.New("Invalid click_method. Expected one of: auto, accessibility, app_post, sky_click, global")
}

func toolDefinitions() []toolDefinition {
	return []toolDefinition{
		{
			Name:        "click",
			Description: "Click an element by generation-bound identifier or pixel coordinates from screenshot. Element-targeted coordinate fallback requires a valid snapshot frame or explicit finite x/y; semantic accessibility clicks may work without a frame. Legacy numeric element indices are rejected; use the complete identifier returned by the latest get_app_state. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Generation-bound element identifier returned by the latest get_app_state"),
				"x":             coordinateProperty("X coordinate in screenshot pixel coordinates"),
				"y":             coordinateProperty("Y coordinate in screenshot pixel coordinates"),
				"click_count":   clickCountProperty("Number of clicks. Defaults to 1"),
				"mouse_button":  enumStringProperty("Mouse button to click. Defaults to left.", []string{"left", "right", "middle"}),
				"click_method":  enumStringProperty("Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. Windows supports app_post through HWND messages; global requires explicit foreground and global-pointer environment authorization. Windows does not support sky_click.", clickMethodValues),
			}, []string{"app"}),
		},
		{
			Name:        "drag",
			Description: "Drag from one point to another using pixel coordinates. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":    stringProperty("App name or bundle identifier"),
				"from_x": coordinateProperty("Start X coordinate"),
				"from_y": coordinateProperty("Start Y coordinate"),
				"to_x":   coordinateProperty("End X coordinate"),
				"to_y":   coordinateProperty("End Y coordinate"),
			}, []string{"app", "from_x", "from_y", "to_x", "to_y"}),
		},
		{
			Name:        "get_app_state",
			Description: "Get the state of an already running app's key window and return its accessibility tree. Set include_image=true to inspect the current screen through a model-visible screenshot; do not simulate operating-system screenshot shortcuts with press_key. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("App name or bundle identifier"),
				"text_limit":     textLimitProperty("Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
				"max_tree_nodes": positiveIntegerProperty("Maximum accessibility tree nodes to render. Defaults to 1200."),
				"max_tree_depth": positiveIntegerProperty("Maximum accessibility tree depth to render. Defaults to 64."),
				"include_image":  booleanProperty("Include a model-visible screenshot for visual inspection. Defaults to false; set true to inspect pixels instead of using press_key for an operating-system screenshot shortcut."),
			}, []string{"app"}),
		},
		{
			Name:        "list_apps",
			Description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{}, nil),
		},
		{
			Name:        "save_screenshot",
			Description: "Capture the key window of an already running Windows app and save the PNG to an absolute file path. Use this only when the user asks to save or export the screenshot; use get_app_state with include_image=true to inspect pixels in the model.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":  stringProperty("App name or bundle identifier"),
				"path": stringProperty("Absolute destination path for the PNG file"),
			}, []string{"app", "path"}),
		},
		{
			Name:        "perform_secondary_action",
			Description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Generation-bound element identifier returned by the latest get_app_state"),
				"action":        stringProperty("Secondary accessibility action name"),
			}, []string{"app", "element_index", "action"}),
		},
		{
			Name:        "press_key",
			Description: "Press a key or key-combination on the keyboard, including modifier and navigation keys. Windows interactive input requires explicit foreground-input authorization and a foreground target; enabling the separate focus-actions flag permits a bounded foreground attempt.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0). This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app": stringProperty("App name or bundle identifier"),
				"key": stringProperty("Key or key-combination to press"),
			}, []string{"app", "key"}),
		},
		{
			Name:        "scroll",
			Description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"direction":     stringProperty("Scroll direction: up, down, left, or right"),
				"element_index": stringProperty("Generation-bound element identifier returned by the latest get_app_state"),
				"pages":         scrollPagesProperty("Number of pages to scroll. Fractional values are supported. Windows semantic scrolling uses one viewport-percent operation. Defaults to 1; maximum 100."),
			}, []string{"app", "element_index", "direction"}),
		},
		{
			Name:        "set_value",
			Description: "Set the value of a settable accessibility element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Generation-bound element identifier returned by the latest get_app_state"),
				"value":         stringProperty("Value to assign"),
			}, []string{"app", "element_index", "value"}),
		},
		{
			Name:        "type_text",
			Description: "Type literal text into the current focused writable text control owned by the requested Windows app and snapshot window. Click/select the field first; this tool never chooses a substitute control or uses top-level keyboard fallback. Use set_value with the complete generation-bound identifier in element_index for exact element targeting. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":  stringProperty("App name or bundle identifier"),
				"text": stringProperty("Literal text to type"),
			}, []string{"app", "text"}),
		},
	}
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	schema := map[string]any{
		"type":                 "object",
		"properties":           properties,
		"additionalProperties": false,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func defaultAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "openWorldHint": false}
}

func readOnlyAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "idempotentHint": true, "openWorldHint": false, "readOnlyHint": true}
}

func stringProperty(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

func enumStringProperty(description string, values []string) map[string]any {
	property := stringProperty(description)
	property["enum"] = values
	return property
}

func booleanProperty(description string) map[string]any {
	return map[string]any{"type": "boolean", "description": description}
}
func numberProperty(description string) map[string]any {
	return map[string]any{"type": "number", "description": description}
}

func coordinateProperty(description string) map[string]any {
	property := numberProperty(description)
	property["minimum"] = -maxCoordinateMagnitude
	property["maximum"] = maxCoordinateMagnitude
	return property
}

func clickCountProperty(description string) map[string]any {
	return map[string]any{
		"type":        "integer",
		"minimum":     1,
		"maximum":     maxClickCount,
		"description": description,
	}
}

func scrollPagesProperty(description string) map[string]any {
	return map[string]any{
		"type":             "number",
		"exclusiveMinimum": 0,
		"maximum":          maxScrollPages,
		"description":      description,
	}
}

func integerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "description": description}
}

func positiveIntegerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "minimum": 1, "description": description}
}

func textLimitProperty(description string) map[string]any {
	return map[string]any{
		"anyOf": []any{
			map[string]any{"type": "integer", "minimum": 1},
			map[string]any{"type": "string", "enum": []string{"max"}},
		},
		"description": description,
	}
}

func main() {
	if err := runCLI(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runCLI(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, helpText(""))
		return nil
	}

	switch args[0] {
	case "-h", "--help", "help":
		topic := ""
		if len(args) > 1 {
			topic = args[1]
		}
		fmt.Fprint(stdout, helpText(topic))
		return nil
	case "-v", "--version", "version":
		fmt.Fprintln(stdout, version)
		return nil
	case "mcp":
		return runMCP(os.Stdin, stdout)
	case "doctor":
		fmt.Fprintln(stdout, "Windows runtime: UI Automation and Win32 window-message bridge are available when this process runs in the signed-in desktop session.")
		return nil
	case "list-apps":
		result := newService().callTool("list_apps", map[string]any{})
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "snapshot":
		app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs(args[1:])
		if err != nil {
			return err
		}
		toolArgs := map[string]any{
			"app": app,
		}
		if textLimit != nil {
			toolArgs["text_limit"] = textLimit.runtimeValue()
		}
		if maxTreeNodes != nil {
			toolArgs["max_tree_nodes"] = *maxTreeNodes
		}
		if maxTreeDepth != nil {
			toolArgs["max_tree_depth"] = *maxTreeDepth
		}
		result := newService().callTool("get_app_state", toolArgs)
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "call":
		output, hasError, err := runCallCommand(args[1:], newService())
		if err != nil {
			return err
		}
		encoded, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, string(encoded))
		if hasError {
			return errors.New("tool call returned isError=true")
		}
		return nil
	default:
		return fmt.Errorf("unknown command: %s\n\n%s", args[0], helpText(""))
	}
}

func parseSnapshotArgs(args []string) (string, *textLimit, *int, *int, error) {
	var app string
	var textLimit *textLimit
	var maxTreeNodes *int
	var maxTreeDepth *int
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--text-limit":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--text-limit requires a positive integer or max value")
			}
			value, err := parseTextLimitOption(args[index], "--text-limit")
			if err != nil {
				return "", nil, nil, nil, err
			}
			textLimit = value
		case "--max-tree-nodes":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-nodes requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-nodes")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeNodes = &value
		case "--max-tree-depth":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-depth requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-depth")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeDepth = &value
		default:
			if strings.HasPrefix(arg, "-") {
				return "", nil, nil, nil, fmt.Errorf("unknown snapshot option: %s", arg)
			}
			if app != "" {
				return "", nil, nil, nil, errors.New("snapshot accepts exactly one app name, process name, window title, or pid")
			}
			app = arg
		}
	}
	if app == "" {
		return "", nil, nil, nil, errors.New("snapshot requires an app name, process name, window title, or pid")
	}
	return app, textLimit, maxTreeNodes, maxTreeDepth, nil
}

func parseTextLimitOption(value, option string) (*textLimit, error) {
	if strings.EqualFold(value, "max") {
		return &textLimit{max: true}, nil
	}
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return nil, fmt.Errorf("%s must be a positive integer or max", option)
	}
	return &textLimit{count: integer}, nil
}

func parsePositiveIntegerOption(value, option string) (int, error) {
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", option)
	}
	return integer, nil
}

func runCallCommand(args []string, svc *service) (any, bool, error) {
	if len(args) == 0 {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}

	var toolName, argsJSON, argsFile, callsJSON, callsFile string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--args":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args requires a value")
			}
			argsJSON = args[index]
		case "--args-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args-file requires a value")
			}
			argsFile = args[index]
		case "--calls":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls requires a value")
			}
			callsJSON = args[index]
		case "--calls-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls-file requires a value")
			}
			callsFile = args[index]
		default:
			if strings.HasPrefix(arg, "-") {
				return nil, false, fmt.Errorf("unknown call option: %s", arg)
			}
			if toolName != "" {
				return nil, false, errors.New("call accepts at most one tool name")
			}
			toolName = arg
		}
	}

	if callsJSON != "" || callsFile != "" {
		if toolName != "" || argsJSON != "" || argsFile != "" {
			return nil, false, errors.New("call sequence does not accept a tool name, --args, or --args-file")
		}
		calls, err := readCallSequence(callsJSON, callsFile)
		if err != nil {
			return nil, false, err
		}
		var outputs []map[string]any
		hasError := false
		for _, call := range calls {
			result := svc.callTool(call.Tool, call.Args)
			outputs = append(outputs, map[string]any{"tool": call.Tool, "result": result})
			if result.IsError {
				hasError = true
				break
			}
		}
		return outputs, hasError, nil
	}

	if toolName == "" {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}
	arguments, err := readArguments(argsJSON, argsFile)
	if err != nil {
		return nil, false, err
	}
	result := svc.callTool(toolName, arguments)
	return result, result.IsError, nil
}

type callSpec struct {
	Tool string
	Args map[string]any
}

func readArguments(inline, file string) (map[string]any, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either inline JSON or a JSON file, not both")
	}
	if inline == "" && file == "" {
		return map[string]any{}, nil
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var raw any
	if err := decodeStrictJSON(source, &raw); err != nil {
		return nil, errors.New("Invalid JSON input.")
	}
	args, ok := raw.(map[string]any)
	if !ok || args == nil {
		return nil, errors.New("--args must be a JSON object")
	}
	return args, nil
}

func readCallSequence(inline, file string) ([]callSpec, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either --calls or --calls-file, not both")
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var raw any
	if err := decodeStrictJSON(source, &raw); err != nil {
		return nil, errors.New("Invalid JSON input.")
	}
	items, ok := raw.([]any)
	if !ok || items == nil {
		return nil, errors.New("--calls must be a JSON array")
	}
	calls := make([]callSpec, 0, len(items))
	for index, rawItem := range items {
		item, ok := rawItem.(map[string]any)
		if !ok || item == nil {
			return nil, fmt.Errorf("call sequence item #%d must be a JSON object", index+1)
		}
		name, namePresent := item["tool"]
		if namePresent {
			nameString, ok := name.(string)
			if !ok {
				return nil, fmt.Errorf("call sequence item #%d tool must be a string", index+1)
			}
			name = strings.TrimSpace(nameString)
		}
		if !namePresent || name == "" {
			name, namePresent = item["name"]
			if namePresent {
				nameString, ok := name.(string)
				if !ok {
					return nil, fmt.Errorf("call sequence item #%d name must be a string", index+1)
				}
				name = strings.TrimSpace(nameString)
			}
		}
		if !namePresent || name == "" {
			return nil, fmt.Errorf("call sequence item #%d requires a non-empty tool", index+1)
		}
		args, err := callArguments(item, index+1)
		if err != nil {
			return nil, err
		}
		calls = append(calls, callSpec{Tool: name.(string), Args: args})
	}
	return calls, nil
}

func callArguments(item map[string]any, itemNumber int) (map[string]any, error) {
	rawArgs, hasArgs := item["args"]
	rawArguments, hasArguments := item["arguments"]
	if hasArgs && hasArguments {
		return nil, fmt.Errorf("call sequence item #%d cannot include both args and arguments", itemNumber)
	}
	if !hasArgs && !hasArguments {
		return map[string]any{}, nil
	}
	raw := rawArgs
	field := "args"
	if !hasArgs {
		raw = rawArguments
		field = "arguments"
	}
	args, ok := raw.(map[string]any)
	if !ok || args == nil {
		return nil, fmt.Errorf("call sequence item #%d %s must be a JSON object", itemNumber, field)
	}
	return args, nil
}

func decodeStrictJSON(source string, destination any) error {
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return errors.New("trailing JSON data")
		}
		return err
	}
	return nil
}

func readJSONSource(inline, file string) (string, error) {
	if inline != "" {
		return inline, nil
	}
	if file == "" {
		return "", errors.New("JSON input is required")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return "", errors.New("Unable to read JSON input file.")
	}
	return string(data), nil
}

func runMCP(stdin io.Reader, stdout io.Writer) error {
	svc := newService()
	decoder := json.NewDecoder(stdin)
	decoder.UseNumber()
	encoder := json.NewEncoder(stdout)
	for {
		var payload any
		if err := decoder.Decode(&payload); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			_ = encoder.Encode(jsonRPCError(nil, -32700, "Invalid JSON-RPC payload"))
			continue
		}
		request, ok := payload.(map[string]any)
		if !ok || request == nil {
			_ = encoder.Encode(jsonRPCError(nil, -32600, "Invalid Request"))
			continue
		}
		response := handleMCPRequest(request, svc)
		if response != nil {
			if err := encoder.Encode(response); err != nil {
				return err
			}
		}
	}
}

func validMCPID(value any) bool {
	switch typed := value.(type) {
	case string:
		return len(typed) <= maxMCPIDLength
	case json.Number:
		if len(typed.String()) == 0 || len(typed.String()) > maxMCPIDLength {
			return false
		}
		number, err := typed.Float64()
		return err == nil && !math.IsNaN(number) && !math.IsInf(number, 0)
	case float32:
		return !math.IsNaN(float64(typed)) && !math.IsInf(float64(typed), 0)
	case float64:
		return !math.IsNaN(typed) && !math.IsInf(typed, 0)
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return true
	default:
		return false
	}
}

func handleMCPRequest(request map[string]any, svc *service) map[string]any {
	if request == nil {
		return jsonRPCError(nil, -32600, "Invalid Request")
	}
	id, hasID := request["id"]
	invalidRequest := func(code int, message string) map[string]any {
		if !hasID {
			return nil
		}
		return jsonRPCError(id, code, message)
	}
	if hasID && !validMCPID(id) {
		return invalidRequest(-32600, "Invalid Request")
	}
	jsonRPCVersion, versionOK := request["jsonrpc"].(string)
	if !versionOK || jsonRPCVersion != "2.0" {
		return invalidRequest(-32600, "Invalid Request")
	}
	method, ok := request["method"].(string)
	if !ok || strings.TrimSpace(method) == "" {
		return invalidRequest(-32600, "Invalid Request")
	}
	reply := func(response map[string]any) map[string]any {
		if !hasID {
			return nil
		}
		return response
	}
	switch method {
	case "initialize":
		if _, err := optionalMCPParams(request); err != nil {
			return reply(jsonRPCError(id, -32602, err.Error()))
		}
		return reply(jsonRPCResult(id, map[string]any{
			"protocolVersion": "2025-03-26",
			"serverInfo": map[string]any{
				"name":    "open-computer-use",
				"version": version,
			},
			"capabilities": map[string]any{"tools": map[string]any{"listChanged": false}},
			"instructions": serverInstructions,
		}))
	case "notifications/initialized", "notifications/turn-ended":
		return nil
	case "ping":
		return reply(jsonRPCResult(id, map[string]any{}))
	case "tools/list":
		if _, err := optionalMCPParams(request); err != nil {
			return reply(jsonRPCError(id, -32602, err.Error()))
		}
		return reply(jsonRPCResult(id, map[string]any{"tools": toolDefinitions()}))
	case "tools/call":
		params, err := requiredMCPParams(request)
		if err != nil {
			return reply(jsonRPCError(id, -32602, err.Error()))
		}
		name, ok := params["name"].(string)
		name = strings.TrimSpace(name)
		if !ok || name == "" {
			return reply(jsonRPCError(id, -32602, "tools/call params.name must be a non-empty string"))
		}
		arguments := map[string]any{}
		if rawArguments, present := params["arguments"]; present {
			var argumentsOK bool
			arguments, argumentsOK = rawArguments.(map[string]any)
			if !argumentsOK || arguments == nil {
				return reply(jsonRPCError(id, -32602, "tools/call params.arguments must be an object"))
			}
		}
		return reply(jsonRPCResult(id, svc.callTool(name, arguments)))
	default:
		return reply(jsonRPCError(id, -32601, "Method not found"))
	}
}

func optionalMCPParams(request map[string]any) (map[string]any, error) {
	raw, present := request["params"]
	if !present {
		return map[string]any{}, nil
	}
	params, ok := raw.(map[string]any)
	if !ok || params == nil {
		return nil, errors.New("params must be an object")
	}
	return params, nil
}

func requiredMCPParams(request map[string]any) (map[string]any, error) {
	raw, present := request["params"]
	if !present || raw == nil {
		return nil, errors.New("tools/call params must be an object")
	}
	params, err := optionalMCPParams(request)
	if err != nil {
		return nil, err
	}
	return params, nil
}

func jsonRPCResult(id any, result any) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
}

func jsonRPCError(id any, code int, message string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   map[string]any{"code": code, "message": message},
	}
}

func helpText(command string) string {
	switch command {
	case "mcp":
		return "Usage:\n  open-computer-use.exe mcp\n\nStart the stdio MCP server.\n"
	case "call":
		return "Usage:\n  open-computer-use.exe call <tool> [--args '<json-object>']\n  open-computer-use.exe call --calls '<json-array>'\n\nThe JSON array form keeps calls in one process, but element identifiers expire whenever a new snapshot is published; use the complete generation-bound identifier from the latest get_app_state.\n"
	case "snapshot":
		return "Usage:\n  open-computer-use.exe snapshot [--text-limit <positive-int|max>] [--max-tree-nodes <positive-int>] [--max-tree-depth <positive-int>] <app>\n\nPrint the current Windows UI Automation snapshot for the target app.\n"
	default:
		return `Open Computer Use for Windows

Usage:
  open-computer-use.exe [command] [options]

Commands:
  mcp                  Start the stdio MCP server.
  doctor               Print Windows runtime notes.
  list-apps            Print running apps with top-level windows.
  snapshot <app>       Print the current UI Automation snapshot for an app.
  call <tool>           Call one tool, or run a JSON array of tool calls.
  help [command]       Show general or command-specific help.
  version              Print the CLI version.

Notes:
  The Windows runtime uses UI Automation first, then Win32 window messages for
  fallback input. Run it in the signed-in desktop session, not as a service.
`
	}
}
