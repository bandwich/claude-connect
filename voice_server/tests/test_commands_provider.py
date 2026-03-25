# voice_server/tests/test_commands_provider.py
import pytest
import os
import tempfile
from voice_server.services.commands_provider import CommandsProvider


class TestCommandsProvider:

    def test_get_builtin_commands_returns_list(self):
        """Builtins should include well-known commands"""
        provider = CommandsProvider()
        commands = provider.get_builtin_commands()
        names = [c["name"] for c in commands]
        assert "compact" in names
        assert "clear" in names
        assert "model" in names
        # Each command has name, description, source
        compact = next(c for c in commands if c["name"] == "compact")
        assert compact["source"] == "builtin"
        assert len(compact["description"]) > 0

    def test_scan_user_skills(self):
        """Should read name + description from SKILL.md frontmatter"""
        with tempfile.TemporaryDirectory() as tmpdir:
            skill_dir = os.path.join(tmpdir, "my-skill")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("---\nname: my-skill\ndescription: Does cool stuff\n---\n\nBody here\n")

            provider = CommandsProvider()
            skills = provider.scan_skills_directory(tmpdir)
            assert len(skills) == 1
            assert skills[0]["name"] == "my-skill"
            assert skills[0]["description"] == "Does cool stuff"
            assert skills[0]["source"] == "skill"

    def test_scan_skills_missing_frontmatter(self):
        """Should use directory name if no frontmatter"""
        with tempfile.TemporaryDirectory() as tmpdir:
            skill_dir = os.path.join(tmpdir, "fallback-skill")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("Just some instructions, no frontmatter\n")

            provider = CommandsProvider()
            skills = provider.scan_skills_directory(tmpdir)
            assert len(skills) == 1
            assert skills[0]["name"] == "fallback-skill"
            assert skills[0]["description"] == ""

    def test_scan_skills_nonexistent_directory(self):
        """Should return empty list for missing directory"""
        provider = CommandsProvider()
        skills = provider.scan_skills_directory("/nonexistent/path")
        assert skills == []

    def test_get_all_commands_merges_builtins_and_skills(self):
        """get_all_commands merges builtins + user skills, deduped by name"""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create a skill that conflicts with a builtin name
            skill_dir = os.path.join(tmpdir, "compact")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("---\nname: compact\ndescription: Custom compact\n---\n")

            # Create a unique skill
            skill_dir2 = os.path.join(tmpdir, "deploy")
            os.makedirs(skill_dir2)
            with open(os.path.join(skill_dir2, "SKILL.md"), "w") as f:
                f.write("---\nname: deploy\ndescription: Deploy app\n---\n")

            provider = CommandsProvider(user_skills_path=tmpdir)
            commands = provider.get_all_commands()
            names = [c["name"] for c in commands]

            # Should have builtins + deploy (compact deduped to builtin)
            assert "deploy" in names
            assert "compact" in names
            # No duplicate compact
            assert names.count("compact") == 1
            # Builtin wins over skill
            compact = next(c for c in commands if c["name"] == "compact")
            assert compact["source"] == "builtin"

    def test_get_all_commands_sorted_alphabetically(self):
        """Commands should be sorted by name"""
        provider = CommandsProvider(user_skills_path="/nonexistent")
        commands = provider.get_all_commands()
        names = [c["name"] for c in commands]
        assert names == sorted(names)
