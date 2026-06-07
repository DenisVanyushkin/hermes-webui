"""Regression tests for the Hindsight disabled-by-default policy."""
from pathlib import Path
from unittest.mock import MagicMock, patch

from api.startup import auto_install_agent_deps


REPO_ROOT = Path(__file__).parent.parent
INIT_SH = (REPO_ROOT / "docker_init.bash").read_text(encoding="utf-8")


def test_docker_init_has_explicit_hindsight_gate():
    assert "assert_hindsight_client_policy" in INIT_SH
    assert "ENABLE_HINDSIGHT" in INIT_SH
    assert "hindsight-client==0.7.2" in INIT_SH
    assert "hindsight-client>=0.4.22" not in INIT_SH
    assert "ensure_hindsight_client_docker_dependency" not in INIT_SH


def test_docker_init_hindsight_guard_distinguishes_optional_metadata():
    assert "tomllib" in INIT_SH
    assert "project.get('dependencies'" in INIT_SH or 'project.get("dependencies"' in INIT_SH
    assert "optional-dependencies" in INIT_SH
    assert "for _manifest in \"$_stage_src/pyproject.toml\" \"$_stage_src/uv.lock\" \"$_stage_src/requirements.txt\"" not in INIT_SH
    assert "ENABLE_HINDSIGHT=false but staged agent metadata mentions hindsight-client" not in INIT_SH


def test_startup_blocks_hindsight_in_default_mode(tmp_path, capsys):
    agent_dir = tmp_path / "hermes-agent"
    agent_dir.mkdir()
    (agent_dir / "requirements.txt").write_text("hindsight-client==0.7.2\n", encoding="utf-8")
    env = {
        "HERMES_WEBUI_AGENT_DIR": str(agent_dir),
        "HERMES_WEBUI_AUTO_INSTALL": "1",
        "ENABLE_HINDSIGHT": "false",
    }
    with patch.dict("os.environ", env, clear=False):
        with patch("api.startup._trusted_agent_dir", return_value=True):
            with patch("subprocess.run") as mock_run:
                assert auto_install_agent_deps() is False
                assert not mock_run.called
    out = capsys.readouterr().out.lower()
    assert "hindsight" in out and "disabled" in out


def test_startup_allows_non_hindsight_agent_sources_in_default_mode(tmp_path):
    agent_dir = tmp_path / "hermes-agent"
    agent_dir.mkdir()
    (agent_dir / "requirements.txt").write_text("pyyaml\n", encoding="utf-8")
    env = {
        "HERMES_WEBUI_AGENT_DIR": str(agent_dir),
        "HERMES_WEBUI_AUTO_INSTALL": "1",
        "ENABLE_HINDSIGHT": "false",
    }
    with patch.dict("os.environ", env, clear=False):
        with patch("api.startup._trusted_agent_dir", return_value=True):
            with patch("subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(returncode=0, stderr="")
                assert auto_install_agent_deps() is True
                args = mock_run.call_args[0][0]
                assert "-r" in args
                assert str(agent_dir / "requirements.txt") in args
