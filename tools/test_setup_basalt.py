#!/usr/bin/env python3
"""The Windows starter's decisions, checked without a GPU, a network or an install.

    python tools/test_setup_basalt.py
    python -m unittest tools.test_setup_basalt     # with the repository root on sys.path

The parts under test read the machine (nvidia-smi rows), the model listing (a Hugging Face tree response), the
release manifest (SHA256SUMS.txt), a release zip and the settings file. All of them take their input as an
argument, so the test feeds them text, a zip and a folder it made.
"""
import importlib.util
import json
import shutil
import tempfile
import unittest
import unittest.mock
import zipfile
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "setup_basalt", Path(__file__).resolve().parent / "windows" / "setup_basalt.py")
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)

SMI_ROWS = """NVIDIA GeForce RTX 5090, 12.0, 24564, 570.124
NVIDIA GeForce RTX 5060 Ti, 12.0, 16311, 570.124
"""


class Machine(unittest.TestCase):
    def test_the_cards_come_out_in_order(self):
        cards = b.parse_nvidia_smi(SMI_ROWS)
        self.assertEqual([c["name"] for c in cards], ["NVIDIA GeForce RTX 5090", "NVIDIA GeForce RTX 5060 Ti"])
        self.assertEqual([c["compute"] for c in cards], [(12, 0), (12, 0)])
        self.assertEqual(cards[0]["memory_mib"], 24564)
        self.assertEqual(cards[0]["driver"], "570.124")

    def test_a_header_and_a_banner_are_not_cards(self):
        text = ("name, compute_cap, memory.total, driver_version\n"
                "Driver Version: 570.124   CUDA Version: 13.0\n" + SMI_ROWS)
        self.assertEqual(len(b.parse_nvidia_smi(text)), 2)

    def test_a_card_of_another_architecture_still_reads(self):
        cards = b.parse_nvidia_smi("NVIDIA GeForce RTX 4090, 8.9, 24564, 550.90.07\n")
        self.assertEqual(cards[0]["compute"], (8, 9))

    def test_nothing_is_a_card_row(self):
        for text in ("", "nvidia-smi: command not found", "12.0, 12.0, 12.0", "a, b, c"):
            self.assertEqual(b.parse_nvidia_smi(text), [], text)


class Packs(unittest.TestCase):
    ENTRIES = [
        {"type": "file", "path": "README.md", "size": 120},
        {"type": "file", "path": "Qwen3.8-FN-Q8_0.basalt", "lfs": {"size": 192 * 1024 ** 3}},
        {"type": "file", "path": "Qwen3.8-FN-UD-IQ1_M.basalt", "lfs": {"size": 70 * 1024 ** 3}},
        {"type": "file", "path": "Qwen3.8-FN-UD-Q4_K_XL.basalt", "size": 115 * 1024 ** 3},
        {"type": "directory", "path": "convert"},
        {"type": "file", "path": "convert/mtp/mtp-manifest.json", "size": 30},
    ]

    def test_the_packs_only_smallest_first(self):
        got = b.parse_hf_tree(self.ENTRIES)
        self.assertEqual([p for p, _ in got],
                         ["Qwen3.8-FN-UD-IQ1_M.basalt", "Qwen3.8-FN-UD-Q4_K_XL.basalt", "Qwen3.8-FN-Q8_0.basalt"])
        self.assertEqual(got[0][1], 70 * 1024 ** 3)

    def test_the_default_pack_is_in_the_listing(self):
        self.assertIn(b.DEFAULT_PACK, [p for p, _ in b.parse_hf_tree(self.ENTRIES)])

    def test_the_default_pack_is_the_smallest(self):
        sizes = {p: s for p, s in b.parse_hf_tree(self.ENTRIES)}
        self.assertEqual(sizes[b.DEFAULT_PACK], min(sizes.values()))


class Release(unittest.TestCase):
    def test_the_asset_name_from_a_manifest(self):
        text = "b2  basalt-0.2.1-win1-windows-x64-cuda13.zip\n9c  SHA256SUMS.txt\n"
        self.assertEqual(b.release_zip_name(text), "basalt-0.2.1-win1-windows-x64-cuda13.zip")
        self.assertEqual(b.sha_from_sums(text, "basalt-0.2.1-win1-windows-x64-cuda13.zip"), "b2")

    def test_nothing_in_the_listing_makes_a_name(self):
        self.assertEqual(b.release_zip_name("Strata-0.2.10-windows-x64-setup.exe  107 MB"), "")
        self.assertEqual(b.sha_from_sums("aa  other.zip", "basalt-1-windows-x64-cuda13.zip"), "")

    def test_the_single_top_folder_of_a_zip_is_stripped(self):
        self.assertEqual(b.zip_root(["x/bin/basalt.exe", "x/serve/server.py"]), "x/")
        self.assertEqual(b.zip_root(["bin/basalt.exe", "serve/server.py"]), "")
        self.assertEqual(b.zip_root(["x/a", "y/b"]), "")

    def test_unpacking_puts_the_engine_beside_serve_and_data(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            zip_path = d / "basalt-1-windows-x64-cuda13.zip"
            with zipfile.ZipFile(zip_path, "w") as z:
                z.writestr(f"basalt-1-windows-x64-cuda13/bin/{b.ENGINE_EXE}", "exe")
                z.writestr("basalt-1-windows-x64-cuda13/serve/server.py", "server")
                z.writestr("basalt-1-windows-x64-cuda13/VERSION", "version: 1")
                z.writestr("basalt-1-windows-x64-cuda13/README-WINDOWS.md", "read me")
            root = d / "install"
            self.assertTrue(b.unpack_zip(zip_path, root))
            self.assertTrue((root / "bin" / b.ENGINE_EXE).is_file())
            self.assertTrue((root / "serve" / "server.py").is_file())
            self.assertFalse((root / "VERSION").exists(), "the release notes are not copied over the tree")

    def test_a_source_checkout_is_never_unpacked_over(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "checkout"
            (root / ".git").mkdir(parents=True)
            (root / "serve").mkdir()
            self.assertIsNone(b.fetch_release(root), "a checkout keeps its own serve/, tools/ and data/")

    def test_downloading_a_file_checks_its_sha(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            src = d / "src.zip"
            src.write_bytes(b"hello")
            good = b.download(src.as_uri(), d / "out" / "src.zip", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            self.assertTrue(good)
            self.assertEqual((d / "out" / "src.zip").read_bytes(), b"hello")
            bad = b.download(src.as_uri(), d / "out2" / "src.zip", "0" * 64)
            self.assertFalse(bad)
            self.assertFalse((d / "out2" / "src.zip").exists(), "a file that fails the check is not kept under its name")


class Settings(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_missing_file_is_no_settings(self):
        self.assertEqual(b.read_config(self.root), {})

    def test_a_file_that_is_not_json_is_kept_aside(self):
        f = self.root / "basalt_config.json"
        f.write_text("{ this is not json", encoding="utf-8")
        self.assertEqual(b.read_config(self.root), {})
        self.assertEqual((self.root / "basalt_config.json.bak").read_text(encoding="utf-8"), "{ this is not json")
        self.assertFalse(f.is_file(), "the broken file moved aside, so the new one is not appended to it")

    def test_the_values_that_are_asked_for_win_over_the_old_ones(self):
        old = {"version": 2, "server": {"port": 9000, "access": "lan"}, "engine": {"kv": "q8"},
               "models": [{"model": "models/old.basalt", "gpu": "0"}]}
        cfg = b.merge_config(old, self.root, self.root / "models" / "new.basalt", "0,1", 8080,
                             {"expert-cache": "auto", "kv": "int8"})
        self.assertEqual(cfg["version"], 2)
        self.assertEqual(cfg["models"][0]["model"], "models/new.basalt",
                         "the chosen model leads the list, inside the folder as a relative path")
        self.assertEqual(cfg["models"][0]["gpu"], "0,1", "the cards asked for go with the model, not the server")
        self.assertEqual([e["model"] for e in cfg["models"]], ["models/new.basalt", "models/old.basalt"],
                         "a model the file already named stays in the list")
        self.assertEqual(cfg["server"]["access"], "lan", "a setting nobody asked about is kept")
        self.assertNotIn("model", cfg["server"], "v2 keeps the model out of the server section")
        self.assertEqual(cfg["server"]["port"], 8080)
        self.assertEqual(cfg["engine"]["kv"], "q8", "the engine's own setting wins over the suggested default")
        self.assertEqual(cfg["engine"]["expert-cache"], "auto", "a suggested default lands when nothing set it")

    def test_choosing_a_listed_model_keeps_its_entry_and_its_settings(self):
        old = {"version": 2, "models": [{"model": "models/a.basalt"}, {"model": "models/b.basalt", "alias": "bee"}]}
        cfg = b.merge_config(old, self.root, self.root / "models" / "b.basalt", "0", 0, {})
        self.assertEqual([e["model"] for e in cfg["models"]], ["models/b.basalt", "models/a.basalt"])
        self.assertEqual(cfg["models"][0].get("alias"), "bee", "the entry's own settings survive the reorder")

    def test_a_model_outside_the_folder_stays_a_full_path(self):
        with tempfile.TemporaryDirectory() as other:
            model = Path(other) / "pack.basalt"
            cfg = b.merge_config({}, self.root, model, "0", 8080, {})
            self.assertEqual(cfg["models"][0]["model"], str(model))

    def test_what_is_written_is_what_is_read_and_needs_no_bom(self):
        cfg = b.merge_config({}, self.root, self.root / "models" / "p.basalt", "0", 8080, {"kv": "int8"})
        f = b.write_config(self.root, cfg)
        self.assertEqual(json.loads(f.read_text(encoding="utf-8"))["engine"]["kv"], "int8")
        self.assertEqual(f.read_bytes()[:3], b"{\n ", "no byte-order mark: the engine reads the file as plain UTF-8")


class V1toV2(unittest.TestCase):
    """The setup migrates the v1 files the older starter wrote, using the tool beside it."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_v2_file_passes_through(self):
        v2 = {"version": 2, "server": {"port": 9000}, "engine": {"expert-cache": "auto"},
              "models": [{"model": "models/a.basalt", "gpu": "0"}]}
        cfg, note, replaced = b.to_v2(v2)
        self.assertEqual(cfg, v2)
        self.assertEqual((note, replaced), ("", False))

    def test_a_v1_file_moves_the_model_into_the_list(self):
        v1 = {"server": {"model": "models/deep.basalt", "gpu": "0,1", "port": 8080},
              "engine": {"kv": "int8", "expert-cache": "auto"}}
        cfg, note, replaced = b.to_v2(v1)
        self.assertFalse(replaced, "the migration tool beside the script reads it")
        self.assertEqual(cfg["version"], 2)
        self.assertEqual(cfg["models"][0]["model"], "models/deep.basalt")
        self.assertEqual(cfg["models"][0]["gpu"], "0,1", "the cards leave \"server\" for the model entry")
        self.assertEqual(cfg["models"][0]["kv"], "int8", "a per-model flag goes into the entry")
        self.assertEqual(cfg["server"], {"port": 8080}, "what the whole server shares stays")
        self.assertEqual(cfg["engine"], {"expert-cache": "auto"}, "what every model takes goes to the top-level engine")

    def test_a_v1_file_naming_no_model_starts_fresh_and_is_kept_aside(self):
        cfg, note, replaced = b.to_v2({"server": {"port": 9000}})
        self.assertEqual(cfg, {"version": 2, "models": []})
        self.assertTrue(replaced, "the caller keeps the file the migration refused as .bak")
        self.assertIn("cannot migrate", note)

    def test_the_migrated_file_is_what_the_setup_then_merges_into(self):
        v1 = {"server": {"model": "models/old.basalt", "port": 9000}}
        migrated, _, _ = b.to_v2(v1)
        cfg = b.merge_config(migrated, self.root, self.root / "models" / "new.basalt", "0", 8080,
                             {"expert-cache": "auto"})
        self.assertEqual([e["model"] for e in cfg["models"]], ["models/new.basalt", "models/old.basalt"])
        self.assertEqual(cfg["server"]["port"], 8080)


class Engine(unittest.TestCase):
    """The engine file is named per platform (basalt.exe, basalt); these tests run on both CI's OSes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.engine = self.root / "bin" / b.ENGINE_EXE

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_release_tree_is_found_before_a_build_tree(self):
        for rel in (self.root / "build" / "bin" / b.ENGINE_EXE, self.engine):
            rel.parent.mkdir(parents=True, exist_ok=True)
            rel.write_text("exe", encoding="utf-8")
        self.assertEqual(b.find_engine(self.root), self.engine.resolve())

    def test_a_source_tree_build_is_found_when_there_is_no_install(self):
        p = self.root / "build" / "bin" / b.ENGINE_EXE
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("exe", encoding="utf-8")
        self.assertEqual(b.find_engine(self.root), p.resolve())

    def test_nothing_installed_is_nothing_found(self):
        self.assertIsNone(b.find_engine(self.root))

    def test_the_build_commands_target_compute_120(self):
        cfg, build = b.build_commands(self.root)
        joined = " ".join(cfg)
        self.assertIn("-DCMAKE_CUDA_ARCHITECTURES=120", joined)
        self.assertIn("-DCMAKE_BUILD_TYPE=Release", joined)
        self.assertEqual(build[:2], ["cmake", "--build"])


class ModelChoices(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "models").mkdir()
        self.local = self.root / "models" / "mine.basalt"
        self.local.write_text("pack", encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_path_that_exists_wins_without_asking(self):
        args = type("A", (), {"model": str(self.local), "yes": True})()
        self.assertEqual(b.choose_model(self.root, args, False, lambda q, d: d), self.local)

    def test_a_name_is_looked_for_in_the_models_folder(self):
        args = type("A", (), {"model": "mine.basalt", "yes": True})()
        self.assertEqual(b.choose_model(self.root, args, False, lambda q, d: d), self.local)

    def test_a_name_that_is_not_there_says_so(self):
        args = type("A", (), {"model": "nope.basalt", "yes": True})()
        self.assertIsNone(b.choose_model(self.root, args, False, lambda q, d: d))

    def test_skip_chooses_nothing(self):
        args = type("A", (), {"model": "skip", "yes": True})()
        self.assertIsNone(b.choose_model(self.root, args, False, lambda q, d: d))

    def test_a_plan_never_downloads(self):
        args = type("A", (), {"model": "default", "yes": True})()
        listing = ([("jesdga/Qwen3.8-Flash-Next-Basalt", "Qwen3.8-FN-UD-IQ1_M.basalt", 70 * 1024 ** 3)], [])
        with unittest.mock.patch.object(b, "hf_packs", lambda: listing):
            self.assertIsNone(b.choose_model(self.root, args, True, lambda q, d: d), "a plan asks for nothing")

    def test_the_default_picks_the_named_pack_across_two_listings(self):
        args = type("A", (), {"model": "default", "yes": True})()
        listing = ([("jesdga/DeepSeek-V4.1-Flash-1017-Basalt", "DeepSeek-V4.1-Flash-1017-UD-IQ1_M.basalt", 242 * 1024 ** 3),
                    ("jesdga/Qwen3.8-Flash-Next-Basalt", b.DEFAULT_PACK, 67 * 1024 ** 3)], [])
        chosen = []
        grab = lambda root_, repo_, path_, size_, args_, plan_, ask_: chosen.append((repo_, path_))
        with unittest.mock.patch.object(b, "hf_packs", lambda: listing), unittest.mock.patch.object(b, "download_pack", grab):
            b.choose_model(self.root, args, True, lambda q, d: d)
        self.assertEqual(chosen, [("jesdga/Qwen3.8-Flash-Next-Basalt", b.DEFAULT_PACK)])

    def test_a_chosen_deepseek_pack_downloads_from_its_own_repo(self):
        args = type("A", (), {"model": "", "yes": True})()
        listing = ([("jesdga/Qwen3.8-Flash-Next-Basalt", b.DEFAULT_PACK, 67 * 1024 ** 3),
                    ("jesdga/DeepSeek-V4.1-Flash-1017-Basalt", "DeepSeek-V4.1-Flash-1017-UD-IQ1_M.basalt", 242 * 1024 ** 3)], [])
        chosen = []
        grab = lambda root_, repo_, path_, size_, args_, plan_, ask_: chosen.append((repo_, path_))
        with unittest.mock.patch.object(b, "hf_packs", lambda: listing), unittest.mock.patch.object(b, "download_pack", grab):
            b.choose_model(self.root, args, False, lambda q, d: "3")   # [1] the local pack, [2] the small Qwen, [3] the DeepSeek
        self.assertEqual(chosen, [("jesdga/DeepSeek-V4.1-Flash-1017-Basalt", "DeepSeek-V4.1-Flash-1017-UD-IQ1_M.basalt")])


class EngineDefaults(unittest.TestCase):
    def test_flash_next_tunes_kv_and_residency(self):
        got = b.engine_defaults(Path("Qwen3.8-FN-NVFP4-DQ6_K.basalt"))
        self.assertEqual(got["kv"], "int8")
        self.assertTrue(got["resident-experts"])

    def test_deepseek_refuses_the_flags_it_does_not_have(self):
        got = b.engine_defaults(Path("DeepSeek-V4.1-Flash-1017-UD-IQ1_M.basalt"))
        self.assertEqual(got, {"expert-cache": "auto"})

    def test_no_model_yet_keeps_the_flash_next_block(self):
        self.assertIn("kv", b.engine_defaults(None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
