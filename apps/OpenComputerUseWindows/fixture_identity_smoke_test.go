//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

type fixtureState struct {
	Ready         bool   `json:"ready"`
	Instance      string `json:"instance"`
	Framework     string `json:"framework"`
	PID           int    `json:"pid"`
	HWND          int64  `json:"hwnd"`
	Title         string `json:"title"`
	WindowBounds  *frame `json:"windowBounds"`
	SetValue      string `json:"setValue"`
	Typed         string `json:"typed"`
	Auto          int    `json:"auto"`
	Accessibility int    `json:"accessibility"`
	AppPost       int    `json:"appPost"`
	Secondary     int    `json:"secondary"`
	EventCount    int    `json:"eventCount"`
	DragValue     int    `json:"dragValue"`
	ScrollEvents  int    `json:"scrollEvents"`
}

func TestWindowsFixtureIdentityAndBoundsSmoke(t *testing.T) {
	if os.Getenv("OPEN_COMPUTER_USE_RUN_WINDOWS_FIXTURE_SMOKE") != "1" {
		t.Skip("set OPEN_COMPUTER_USE_RUN_WINDOWS_FIXTURE_SMOKE=1 for the interactive Windows fixture smoke")
	}

	runDir := t.TempDir()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate fixture smoke test source")
	}
	fixturePath := filepath.Join(filepath.Dir(sourceFile), "fixtures", "wpf-test-bench.ps1")
	var processes []*os.Process
	defer func() {
		for _, process := range processes {
			if process == nil {
				continue
			}
			_ = process.Kill()
		}
	}()

	start := func(instance string, left, top int) (*fixtureState, *os.Process) {
		readyPath := filepath.Join(runDir, instance+"-ready.json")
		statePath := filepath.Join(runDir, instance+"-state.json")
		cmd := exec.Command("pwsh.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", fixturePath,
			"-InstanceName", instance, "-ReadyPath", readyPath, "-StatePath", statePath,
			"-Left", fmt.Sprintf("%d", left), "-Top", fmt.Sprintf("%d", top))
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Start(); err != nil {
			t.Fatalf("start fixture %s: %v", instance, err)
		}
		processes = append(processes, cmd.Process)
		state := waitForFixtureState(t, readyPath, statePath, instance)
		return state, cmd.Process
	}

	stateA, _ := start("A", 20, 20)
	stateB, _ := start("B", 1280, 20)
	if stateA.PID == stateB.PID || stateA.HWND == stateB.HWND {
		t.Fatalf("fixtures did not receive distinct identities: A=%+v B=%+v", stateA, stateB)
	}
	baselineB := *stateB

	svc := newService()
	result := svc.getAppState(stateA.Title, nil, nil, nil, false)
	if result.IsError {
		t.Fatalf("get_app_state A: %s", result.Content[0].Text)
	}
	snapshotA := svc.currentSnapshot(stateA.Title)
	if snapshotA == nil || snapshotA.App.PID != stateA.PID || snapshotA.App.MainWindowHandle != stateA.HWND {
		t.Fatalf("snapshot A identity mismatch: snapshot=%+v state=%+v", snapshotA, stateA)
	}
	setRecord := findFixtureElement(snapshotA, "Set value target")
	if setRecord == nil {
		t.Fatal("set value element missing from A snapshot")
	}

	// The mutable app selector names B, but the immutable identity names A.
	crossQuery := psRequest{
		Tool:                     "set_value",
		App:                      stateB.Title,
		Element:                  setRecord,
		Value:                    "identity-pinned-a",
		ExpectedPID:              snapshotA.App.PID,
		ExpectedStartTimeTicks:   snapshotA.App.ProcessStartTimeTicks,
		ExpectedMainWindowHandle: snapshotA.App.MainWindowHandle,
	}
	response, err := runPowerShell(crossQuery)
	if err != nil || !response.OK {
		t.Fatalf("identity-pinned cross-query action failed: err=%v response=%+v", err, response)
	}
	stateA = waitForFixtureValue(t, filepath.Join(runDir, "A-state.json"), func(state fixtureState) bool { return state.SetValue == "identity-pinned-a" })
	stateB = readFixtureState(t, filepath.Join(runDir, "B-state.json"))
	if stateB.SetValue != baselineB.SetValue {
		t.Fatalf("cross-query action changed B: before=%+v after=%+v", baselineB, stateB)
	}

	badIdentity := crossQuery
	badIdentity.ExpectedPID = stateB.PID
	badIdentity.ExpectedStartTimeTicks = snapshotA.App.ProcessStartTimeTicks
	badResponse, badErr := runPowerShell(badIdentity)
	if badErr != nil {
		t.Fatal(badErr)
	}
	if badResponse.OK || !strings.Contains(badResponse.Error, "Target changed; call get_app_state again.") {
		t.Fatalf("mismatched identity was not rejected: %+v", badResponse)
	}
	stateAAfterIdentity := readFixtureState(t, filepath.Join(runDir, "A-state.json"))
	stateBAfterIdentity := readFixtureState(t, filepath.Join(runDir, "B-state.json"))
	if stateAAfterIdentity.SetValue != stateA.SetValue || !sameFixtureObservableState(&baselineB, stateBAfterIdentity) {
		t.Fatalf("mismatched identity changed fixture state: A=%+v B=%+v", stateAAfterIdentity, stateBAfterIdentity)
	}

	for _, action := range setRecord.Actions {
		if action == "Invoke" {
			t.Fatal("the missing-frame click regression target unexpectedly exposes InvokePattern")
		}
	}
	clickRecord := *setRecord
	clickRecord.Frame = nil
	clickBaseline := readFixtureState(t, filepath.Join(runDir, "A-state.json"))
	t.Setenv("OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT", "1")
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
	for _, method := range []string{"auto", "app_post", "global"} {
		missingFrameResponse, missingFrameErr := runPowerShell(psRequest{
			Tool:                     "click",
			App:                      stateA.Title,
			Element:                  &clickRecord,
			ClickCount:               1,
			MouseButton:              "left",
			ClickMethod:              method,
			WindowBounds:             snapshotA.WindowBounds,
			ExpectedPID:              snapshotA.App.PID,
			ExpectedStartTimeTicks:   snapshotA.App.ProcessStartTimeTicks,
			ExpectedMainWindowHandle: snapshotA.App.MainWindowHandle,
		})
		if missingFrameErr != nil {
			t.Fatalf("missing-frame %s click invocation: %v", method, missingFrameErr)
		}
		if missingFrameResponse.OK || missingFrameResponse.Error != "Click requires an element with a valid frame or explicit finite x/y coordinates." {
			t.Fatalf("missing-frame %s click was not rejected with the bounded frame error: %+v", method, missingFrameResponse)
		}
		clickAfter := readFixtureState(t, filepath.Join(runDir, "A-state.json"))
		if !sameFixtureObservableState(clickBaseline, clickAfter) {
			t.Fatalf("missing-frame %s click changed fixture state: before=%+v after=%+v", method, clickBaseline, clickAfter)
		}
	}

	if snapshotA.WindowBounds == nil {
		t.Fatal("snapshot A has no bounds")
	}
	moveFixtureWindow(t, snapshotA.App.MainWindowHandle, int(snapshotA.WindowBounds.X)+20, int(snapshotA.WindowBounds.Y))
	waitForFixtureWindowMove(t, snapshotA.App.MainWindowHandle, int(snapshotA.WindowBounds.X), int(snapshotA.WindowBounds.Y))
	staleDrag := psRequest{
		Tool:                     "drag",
		App:                      stateA.Title,
		FromX:                    floatPointer(100),
		FromY:                    floatPointer(250),
		ToX:                      floatPointer(400),
		ToY:                      floatPointer(250),
		WindowBounds:             &frame{X: snapshotA.WindowBounds.X, Y: snapshotA.WindowBounds.Y, Width: snapshotA.WindowBounds.Width, Height: snapshotA.WindowBounds.Height},
		ExpectedPID:              snapshotA.App.PID,
		ExpectedStartTimeTicks:   snapshotA.App.ProcessStartTimeTicks,
		ExpectedMainWindowHandle: snapshotA.App.MainWindowHandle,
	}
	staleResponse, staleErr := runPowerShell(staleDrag)
	if staleErr != nil {
		t.Fatal(staleErr)
	}
	if staleResponse.OK || !strings.Contains(staleResponse.Error, "Target changed; call get_app_state again.") {
		t.Fatalf("stale bounds were not rejected: %+v", staleResponse)
	}
}

func findFixtureElement(snapshot *appSnapshot, name string) *elementRecord {
	for _, record := range snapshot.Elements {
		if record.Name != name {
			continue
		}
		settable := false
		for _, action := range record.Actions {
			if action == "SetValue" {
				settable = true
				break
			}
		}
		if !settable && !strings.Contains(strings.ToLower(record.ControlType), "edit") {
			continue
		}
		copy := record
		return &copy
	}
	return nil
}

func sameFixtureObservableState(left, right *fixtureState) bool {
	if left == nil || right == nil {
		return false
	}
	return left.SetValue == right.SetValue &&
		left.Typed == right.Typed &&
		left.Auto == right.Auto &&
		left.Accessibility == right.Accessibility &&
		left.AppPost == right.AppPost &&
		left.Secondary == right.Secondary &&
		left.EventCount == right.EventCount &&
		left.DragValue == right.DragValue &&
		left.ScrollEvents == right.ScrollEvents
}

func floatPointer(value float64) *float64 {
	return &value
}

func waitForFixtureState(t *testing.T, readyPath, statePath, instance string) *fixtureState {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	lastObservation := "state file not present"
	for time.Now().Before(deadline) {
		state, err := readFixtureStateIfReady(statePath)
		if err != nil {
			lastObservation = err.Error()
		} else if state.Ready && state.Instance == instance && state.PID > 0 && state.HWND != 0 {
			if _, err := os.Stat(readyPath); err == nil {
				return state
			}
			lastObservation = "state ready but ready file is missing"
		} else {
			lastObservation = fmt.Sprintf("state not ready: %+v", *state)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("fixture %s did not become ready: %s (%s)", instance, statePath, lastObservation)
	return nil
}

func waitForFixtureValue(t *testing.T, statePath string, predicate func(fixtureState) bool) *fixtureState {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		state := readFixtureState(t, statePath)
		if predicate(*state) {
			return state
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("fixture state did not reach expected value: %s", statePath)
	return nil
}

func readFixtureStateIfReady(path string) (*fixtureState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var state fixtureState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	return &state, nil
}

func readFixtureState(t *testing.T, path string) *fixtureState {
	t.Helper()
	state, err := readFixtureStateIfReady(path)
	if err != nil {
		t.Fatalf("read fixture state %s: %v", path, err)
	}
	return state
}

func moveFixtureWindow(t *testing.T, hwnd int64, left, top int) {
	t.Helper()
	user32 := syscall.NewLazyDLL("user32.dll")
	setWindowPos := user32.NewProc("SetWindowPos")
	const swpNoSize = 0x0001
	const swpNoZOrder = 0x0004
	const swpShowWindow = 0x0040
	result, _, err := setWindowPos.Call(uintptr(hwnd), 0, uintptr(left), uintptr(top), 0, 0, swpNoSize|swpNoZOrder|swpShowWindow)
	if result == 0 {
		t.Fatalf("SetWindowPos failed: %v", err)
	}
}

type fixtureWindowRect struct {
	Left   int32
	Top    int32
	Right  int32
	Bottom int32
}

func fixtureWindowPosition(hwnd int64) (int, int, error) {
	user32 := syscall.NewLazyDLL("user32.dll")
	getWindowRect := user32.NewProc("GetWindowRect")
	var rect fixtureWindowRect
	result, _, err := getWindowRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&rect)))
	if result == 0 {
		return 0, 0, err
	}
	return int(rect.Left), int(rect.Top), nil
}

func waitForFixtureWindowMove(t *testing.T, hwnd int64, oldLeft, oldTop int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		left, top, err := fixtureWindowPosition(hwnd)
		if err == nil && (left != oldLeft || top != oldTop) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("fixture HWND %d did not move from (%d,%d)", hwnd, oldLeft, oldTop)
}
