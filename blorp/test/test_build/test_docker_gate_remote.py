#!/usr/bin/env python3
"""Behaviour of `scripts/docker-gate` with BLORP_DOCKER_GATE_HOST set.

A fake `ssh` on PATH runs each "remote" command on this machine, so a
temporary repository stands in for the remote one. The gate itself runs with
--dry-run, which prints its Docker commands without needing Docker.
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FAKE_HOST = "gate-host"

# Runs the command after the host locally. FAKE_SSH_UNREACHABLE fails every
# connection; FAKE_SSH_FAIL_STEP fails the connection whose remote command
# names that step, as `remote_bash` does.
FAKE_SSH = textwrap.dedent(
    """\
    #!/bin/bash
    echo "$*" >> "$FAKE_SSH_LOG"
    while [ $# -gt 0 ]; do
        case "$1" in
            -o|-p|-i|-l|-F|-J) shift 2 ;;
            -*) shift ;;
            *) break ;;
        esac
    done
    shift
    [ -n "${FAKE_SSH_UNREACHABLE:-}" ] && exit 255
    if [ -n "${FAKE_SSH_FAIL_STEP:-}" ] && [ "$*" = "bash -s -- $FAKE_SSH_FAIL_STEP" ]; then
        exit 255
    fi
    export HOME="$FAKE_REMOTE_HOME"
    cd "$HOME" && exec bash -c "$*"
    """
)

# Prints only in the copy of the script that the remote run starts, which
# unsets BLORP_DOCKER_GATE_HOST, so the marker shows that an uncommitted edit
# reached the remote worktree.
REMOTE_MARKER = "REMOTE-SNAPSHOT-MARKER"


def wait_for(condition, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.2)
    return condition()


class DockerGateRemoteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix="docker-gate-remote."))
        self.checkout = self.scratch / "checkout"
        (self.checkout / "scripts").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts" / "docker-gate", self.checkout / "scripts" / "docker-gate")
        shutil.copytree(ROOT / "scripts" / "docker", self.checkout / "scripts" / "docker")
        (self.checkout / ".gitignore").write_text(".env\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")

        self.remote_home = self.scratch / "remote-home"
        self.remote_home.mkdir()
        bin_dir = self.scratch / "bin"
        bin_dir.mkdir()
        fake_ssh = bin_dir / "ssh"
        fake_ssh.write_text(FAKE_SSH)
        fake_ssh.chmod(0o755)
        # The probe asks the remote for docker; a stub answers for it.
        fake_docker = bin_dir / "docker"
        fake_docker.write_text('#!/bin/bash\n[ -z "${FAKE_DOCKER_DOWN:-}" ]\n')
        fake_docker.chmod(0o755)
        # Free space in the remote home, in KiB, as `df -Pk` reports it.
        fake_df = bin_dir / "df"
        fake_df.write_text(
            '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\n'
            'echo "disk 999999999 1 ${FAKE_DF_FREE_KIB:-999999999} 1% /"\n'
        )
        fake_df.chmod(0o755)
        self.ssh_log = self.scratch / "ssh.log"

        self.environment = dict(os.environ)
        self.environment.update(
            {
                "PATH": f"{bin_dir}:{self.environment['PATH']}",
                "BLORP_DOCKER_GATE_HOST": FAKE_HOST,
                "BLORP_DOCKER_GATE_REMOTE_REPO": "gate-repo",
                "BLORP_DOCKER_GATE_SLOT_DIR": str(self.scratch / "slots"),
                "FAKE_SSH_LOG": str(self.ssh_log),
                "FAKE_REMOTE_HOME": str(self.remote_home),
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t",
            }
        )
        self.environment.pop("GIT_SSH_COMMAND", None)
        self.environment.pop("BLORP_DOCKER_GATE_REMOTE_MAX_CONCURRENT", None)

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.checkout,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout

    def edit_gate_script_uncommitted(self, line: str) -> None:
        script = self.checkout / "scripts" / "docker-gate"
        text = script.read_text()
        first_line, rest = text.split("\n", 1)
        script.write_text(
            f'{first_line}\n[ -z "${{BLORP_DOCKER_GATE_HOST:-}}" ] && {line}\n{rest}'
        )

    def run_gate(
        self,
        cwd: Path | None = None,
        gate_args: tuple[str, ...] = (),
        **extra_environment: str,
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(self.environment)
        environment.update(extra_environment)
        return subprocess.run(
            ["scripts/docker-gate", "--dry-run", "--platform", "linux/arm64", *gate_args],
            cwd=cwd or self.checkout,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )

    def remote_repo(self) -> Path:
        return self.remote_home / "gate-repo"

    def test_reachable_host_runs_the_working_tree_remotely_and_cleans_up(self) -> None:
        self.edit_gate_script_uncommitted(
            f"echo {REMOTE_MARKER} cap=$BLORP_DOCKER_GATE_MAX_CONCURRENT"
            " files=$(ls untracked.txt .env 2>/dev/null | tr '\\n' ,)"
        )
        untracked = self.checkout / "untracked.txt"
        untracked.write_text("new file\n")
        (self.checkout / ".env").write_text("BLORP_DOCKER_GATE_UNUSED=1\n")
        status_before = self.git("status", "--porcelain")

        completed = self.run_gate()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"Running the gate on {FAKE_HOST}", completed.stdout)
        # The remote run gets the remote cap, not this machine's, and a
        # worktree holding the untracked file but not the ignored .env.
        self.assertIn(f"{REMOTE_MARKER} cap=10 files=untracked.txt,", completed.stdout)
        self.assertIn("docker run", completed.stdout)
        self.assertNotIn("running the gate locally", completed.stderr)
        # Each connection is independent of any shared ControlMaster.
        ssh_calls = self.ssh_log.read_text().splitlines()
        self.assertTrue(ssh_calls)
        for call in ssh_calls:
            self.assertIn("ControlMaster=no", call)
            self.assertIn("ControlPath=none", call)
        # The checkout is untouched, and nothing is left behind remotely.
        self.assertEqual(self.git("status", "--porcelain"), status_before)
        remote = self.remote_repo()
        self.assertEqual(self.git("for-each-ref", "refs/blorp-docker-gate", cwd=remote), "")
        self.assertEqual(len(self.git("worktree", "list", cwd=remote).splitlines()), 1)

    def test_remote_gate_failure_is_returned_and_not_rerun_locally(self) -> None:
        self.edit_gate_script_uncommitted("exit 7")

        completed = self.run_gate()

        self.assertEqual(completed.returncode, 7, completed.stderr)
        self.assertNotIn("running the gate locally", completed.stderr)
        self.assertNotIn("docker run", completed.stdout)

    def test_remote_gate_exit_255_is_not_mistaken_for_a_lost_connection(self) -> None:
        self.edit_gate_script_uncommitted("exit 255")

        completed = self.run_gate()

        self.assertEqual(completed.returncode, 254, completed.stderr)
        self.assertNotIn("running the gate locally", completed.stderr)

    def test_gate_arguments_reach_the_remote_unchanged(self) -> None:
        completed = self.run_gate(gate_args=("--", "two words", "$HOME", "it's"))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"Running the gate on {FAKE_HOST}", completed.stdout)
        self.assertIn("entrypoint two\\ words \\$HOME it\\'s", completed.stdout)

    def test_stopped_docker_on_the_host_runs_the_gate_locally(self) -> None:
        completed = self.run_gate(FAKE_DOCKER_DOWN="1")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            f"the Docker daemon on {FAKE_HOST} is not running; running the gate locally",
            completed.stderr,
        )

    def test_stale_refs_from_cut_off_runs_are_swept(self) -> None:
        remote = self.remote_repo()
        remote.mkdir()
        self.git("init", "-q", cwd=remote)
        head = self.git("rev-parse", "HEAD").strip()
        self.git("push", "-q", str(remote), f"{head}:refs/blorp-docker-gate/1000-old-1")

        completed = self.run_gate()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.git("for-each-ref", "refs/blorp-docker-gate", cwd=remote), "")

    def test_nearly_full_host_runs_the_gate_locally(self) -> None:
        completed = self.run_gate(FAKE_DF_FREE_KIB=str(5 * 1024 * 1024))

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            f"{FAKE_HOST} has less than 20 GiB free; running the gate locally",
            completed.stderr,
        )

    def test_unreadable_free_space_does_not_block_the_host(self) -> None:
        completed = self.run_gate(FAKE_DF_FREE_KIB="-")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"Running the gate on {FAKE_HOST}", completed.stdout)

    def test_without_origin_main_no_base_ref_is_pushed(self) -> None:
        completed = self.run_gate()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            self.git("for-each-ref", "refs/blorp-docker-gate-base", cwd=self.remote_repo()), ""
        )

    def test_push_keeps_a_persistent_base_ref_for_main(self) -> None:
        head = self.git("rev-parse", "HEAD").strip()
        self.git("update-ref", "refs/remotes/origin/main", head)

        completed = self.run_gate()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            self.git("rev-parse", "refs/blorp-docker-gate-base/main", cwd=self.remote_repo()).strip(),
            head,
        )

    def test_unreachable_host_runs_the_gate_locally(self) -> None:
        completed = self.run_gate(FAKE_SSH_UNREACHABLE="1")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"{FAKE_HOST} is unreachable over SSH; running the gate locally", completed.stderr)
        self.assertIn("docker run", completed.stdout)
        self.assertNotIn(f"Running the gate on {FAKE_HOST}", completed.stdout)

    def test_lost_connection_during_the_gate_returns_255_without_a_local_rerun(self) -> None:
        completed = self.run_gate(FAKE_SSH_FAIL_STEP="run")

        self.assertEqual(completed.returncode, 255, completed.stderr)
        self.assertIn(f"Running the gate on {FAKE_HOST}", completed.stdout)
        self.assertNotIn("running the gate locally", completed.stderr)
        self.assertNotIn("docker run", completed.stdout)

    def test_killing_the_local_gate_stops_the_remote_gate(self) -> None:
        started = self.remote_home / "started"
        stopped = self.remote_home / "stopped"
        # The remote gate blocks until it is signalled, recording both.
        self.edit_gate_script_uncommitted(
            f"{{ echo > {started}; "
            f"trap 'echo > {stopped}; kill $! 2>/dev/null; exit 143' TERM; "
            "sleep 60 & wait; }"
        )
        environment = dict(self.environment)
        gate = subprocess.Popen(
            ["scripts/docker-gate", "--dry-run", "--platform", "linux/arm64"],
            cwd=self.checkout,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            self.assertTrue(wait_for(started.exists, 60), "the remote gate never started")
            # An agent's harness may kill only this process, by any signal. The
            # fake ssh execs its remote shell, so this kills that shell too: it
            # covers the watcher's "shell gone" case. A real sshd instead leaves
            # the shell running under a new parent, the case checked on a host.
            gate.send_signal(signal.SIGKILL)
            gate.wait(timeout=10)
            self.assertTrue(wait_for(stopped.exists, 30), "the remote gate kept running")
        finally:
            if gate.poll() is None:
                gate.kill()

    def test_main_checkout_env_file_selects_the_host_from_a_worktree(self) -> None:
        del self.environment["BLORP_DOCKER_GATE_HOST"]
        (self.checkout / ".env").write_text(
            f'# local settings\nexport BLORP_DOCKER_GATE_HOST="{FAKE_HOST}"\nOTHER=ignored\n'
        )
        worktree = self.scratch / "worktree"
        self.git("worktree", "add", "-q", "--detach", str(worktree))

        completed = self.run_gate(cwd=worktree)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"Running the gate on {FAKE_HOST}", completed.stdout)
        # The ignored .env is not part of the snapshot sent to the host.
        self.assertNotIn(".env", self.git("ls-tree", "-r", "--name-only", "HEAD", cwd=worktree))

    def test_environment_overrides_the_env_file(self) -> None:
        (self.checkout / ".env").write_text("BLORP_DOCKER_GATE_HOST=elsewhere\n")

        completed = self.run_gate(BLORP_DOCKER_GATE_HOST="")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("Running the gate on", completed.stdout)
        self.assertFalse(self.ssh_log.exists())


if __name__ == "__main__":
    unittest.main()
