//! Regression tests for env-backed bool flags.
//!
//! Clap's default bool parser accepts only `true` and `false`. `NO_COLOR=1`
//! and `HN_JSON=1` used to exit before the command ran.

use std::path::Path;
use std::process::{Command, Output};

fn output(args: &[&str], env: &[(&str, &str)]) -> Output {
    let dir = tempfile::tempdir().expect("temp config dir");
    command(args, env, dir.path()).output().expect("spawn hn")
}

fn command(args: &[&str], env: &[(&str, &str)], config: &Path) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_hn"));
    cmd.args(args)
        .env("HN_CONFIG_DIR", config)
        .env_remove("NO_COLOR")
        .env_remove("HN_JSON");
    for (key, value) in env {
        cmd.env(key, value);
    }
    cmd
}

fn stdout(output: &Output) -> String {
    String::from_utf8(output.stdout.clone()).expect("stdout utf-8")
}

fn stderr(output: &Output) -> String {
    String::from_utf8(output.stderr.clone()).expect("stderr utf-8")
}

fn assert_ran(output: &Output, context: &str) {
    assert!(
        output.status.success(),
        "{context} failed ({:?})\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        stdout(output),
        stderr(output)
    );
    assert!(
        !stderr(output).contains("invalid value"),
        "{context} rejected an env value:\n{}",
        stderr(output)
    );
}

#[test]
fn no_color_one_does_not_abort_whoami() {
    let output = output(&["whoami"], &[("NO_COLOR", "1")]);
    assert_ran(&output, "NO_COLOR=1 hn whoami");
    assert!(stdout(&output).contains("Not logged in"));
}

#[test]
fn no_color_true_does_not_abort() {
    let output = output(&["whoami"], &[("NO_COLOR", "true")]);
    assert_ran(&output, "NO_COLOR=true hn whoami");
    assert!(stdout(&output).contains("Not logged in"));
}

#[test]
fn empty_no_color_does_not_abort() {
    let output = output(&["whoami"], &[("NO_COLOR", "")]);
    assert_ran(&output, "empty NO_COLOR hn whoami");
    assert!(stdout(&output).contains("Not logged in"));
}

#[test]
fn arbitrary_no_color_values_do_not_abort() {
    for value in ["yes", "anything", "false", "0"] {
        let output = output(&["capabilities"], &[("NO_COLOR", value)]);
        assert_ran(&output, &format!("NO_COLOR={value} hn capabilities"));
        assert!(stdout(&output).contains("\"name\": \"hn\""));
    }
}

#[test]
fn bare_no_color_flag_runs() {
    let output = output(&["--no-color", "whoami"], &[]);
    assert_ran(&output, "hn --no-color whoami");
    assert!(stdout(&output).contains("Not logged in"));
}

#[test]
fn hn_json_one_selects_json_output() {
    let output = output(&["drafts"], &[("HN_JSON", "1")]);
    assert_ran(&output, "HN_JSON=1 hn drafts");
    assert_eq!(stdout(&output).trim(), "{}");
}

#[test]
fn hn_json_true_and_yes_select_json_output() {
    for value in ["true", "yes"] {
        let output = output(&["drafts"], &[("HN_JSON", value)]);
        assert_ran(&output, &format!("HN_JSON={value} hn drafts"));
        assert_eq!(stdout(&output).trim(), "{}");
    }
}

#[test]
fn hn_json_false_and_zero_leave_human_output() {
    for value in ["false", "0", "no", "off"] {
        let output = output(&["drafts"], &[("HN_JSON", value)]);
        assert_ran(&output, &format!("HN_JSON={value} hn drafts"));
        assert!(stdout(&output).contains("No saved drafts"));
        assert!(!stdout(&output).trim().starts_with('{'));
    }
}

#[test]
fn empty_hn_json_is_unset() {
    let output = output(&["drafts"], &[("HN_JSON", "")]);
    assert_ran(&output, "empty HN_JSON hn drafts");
    assert!(stdout(&output).contains("No saved drafts"));
}

#[test]
fn bare_json_flag_selects_json_output() {
    let output = output(&["--json", "drafts"], &[]);
    assert_ran(&output, "hn --json drafts");
    assert_eq!(stdout(&output).trim(), "{}");
}

#[test]
fn json_flag_wins_over_falsey_hn_json() {
    let output = output(&["--json", "drafts"], &[("HN_JSON", "0")]);
    assert_ran(&output, "HN_JSON=0 hn --json drafts");
    assert_eq!(stdout(&output).trim(), "{}");
}

#[test]
fn no_color_and_hn_json_can_both_be_one() {
    let output = output(&["drafts"], &[("NO_COLOR", "1"), ("HN_JSON", "1")]);
    assert_ran(&output, "NO_COLOR=1 HN_JSON=1 hn drafts");
    assert_eq!(stdout(&output).trim(), "{}");
}

#[test]
fn help_still_shows_both_flags() {
    let output = output(&["--help"], &[]);
    assert_ran(&output, "hn --help");
    let text = stdout(&output);
    assert!(text.contains("--no-color"));
    assert!(text.contains("--json"));
    assert!(text.contains("NO_COLOR"));
    assert!(text.contains("HN_JSON"));
    assert!(!text.contains("possible values"));
}

const PTY_SCRIPT: &str = r#"
import os, sys
bin_path = sys.argv[1]
args = sys.argv[2:]
master, slave = os.openpty()
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    os.execv(bin_path, [bin_path, *args])
os.close(slave)
chunks = []
while True:
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    chunks.append(data)
os.close(master)
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(b"".join(chunks))
raise SystemExit(os.waitstatus_to_exitcode(status))
"#;

fn pty_drafts(env: &[(&str, &str)], args: &[&str]) -> String {
    let dir = tempfile::tempdir().expect("temp config dir");
    std::fs::write(
        dir.path().join("drafts.json"),
        r#"{"comment:1":{"text":"hello from the draft","saved_at":"2026-01-01T00:00:00Z"}}"#,
    )
    .expect("seed draft");

    let mut cmd = Command::new("python3");
    cmd.arg("-c")
        .arg(PTY_SCRIPT)
        .arg(env!("CARGO_BIN_EXE_hn"))
        .args(args)
        .env("HN_CONFIG_DIR", dir.path())
        .env_remove("NO_COLOR")
        .env_remove("HN_JSON");
    for (key, value) in env {
        cmd.env(key, value);
    }
    let output = cmd.output().expect("spawn python pty");
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    assert!(
        output.status.success(),
        "pty hn {:?} env {env:?} failed ({:?}): {text}",
        args,
        output.status.code()
    );
    assert!(
        text.contains("comment:1"),
        "draft listing missing from pty output: {text:?}"
    );
    text
}

#[test]
fn no_color_one_strips_ansi_on_a_terminal() {
    let text = pty_drafts(&[("NO_COLOR", "1")], &["drafts"]);
    assert!(
        !text.contains('\u{1b}'),
        "NO_COLOR=1 still colored: {text:?}"
    );
}

#[test]
fn no_color_true_strips_ansi_on_a_terminal() {
    let text = pty_drafts(&[("NO_COLOR", "true")], &["drafts"]);
    assert!(
        !text.contains('\u{1b}'),
        "NO_COLOR=true still colored: {text:?}"
    );
}

#[test]
fn empty_no_color_keeps_terminal_color() {
    let text = pty_drafts(&[("NO_COLOR", "")], &["drafts"]);
    assert!(
        text.contains("\u{1b}[1mcomment:1"),
        "empty NO_COLOR disabled color: {text:?}"
    );
}

#[test]
fn unset_no_color_keeps_terminal_color() {
    let text = pty_drafts(&[], &["drafts"]);
    assert!(
        text.contains("\u{1b}[1mcomment:1"),
        "unset NO_COLOR disabled color: {text:?}"
    );
}

#[test]
fn bare_no_color_flag_strips_ansi_on_a_terminal() {
    let text = pty_drafts(&[], &["--no-color", "drafts"]);
    assert!(
        !text.contains('\u{1b}'),
        "--no-color still colored: {text:?}"
    );
}

#[test]
fn bare_no_color_flag_wins_when_no_color_is_empty() {
    let text = pty_drafts(&[("NO_COLOR", "")], &["--no-color", "drafts"]);
    assert!(
        !text.contains('\u{1b}'),
        "--no-color with empty NO_COLOR still colored: {text:?}"
    );
}
