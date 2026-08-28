import os
import tempfile
import unittest
from unittest import mock

from regicide_update import cli_update, common as rc, snapshots


class CliUpdateTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        overlay_dir = self.tmpdir.name
        snapshot_dir = os.path.join(overlay_dir, "snapshots")
        roots_dir = os.path.join(self.tmpdir.name, "roots")
        os.makedirs(snapshot_dir)
        os.makedirs(roots_dir)

        self.patch_overlay = mock.patch.object(rc, "OVERLAY_DIR", overlay_dir)
        self.patch_roots = mock.patch.object(rc, "ROOTS_DIR", roots_dir)
        self.patch_snapshots = mock.patch.object(rc, "SNAPSHOT_DIR", snapshot_dir)
        self.patch_current = mock.patch.object(
            rc, "CURRENT_FILE", os.path.join(overlay_dir, ".regicide-current")
        )
        self.patch_revert = mock.patch.object(
            rc, "REVERT_FLAG", os.path.join(roots_dir, ".regicide-revert")
        )
        self.patch_overlay.start()
        self.patch_roots.start()
        self.patch_snapshots.start()
        self.patch_current.start()
        self.patch_revert.start()
        self.addCleanup(self.patch_overlay.stop)
        self.addCleanup(self.patch_roots.stop)
        self.addCleanup(self.patch_snapshots.stop)
        self.addCleanup(self.patch_current.stop)
        self.addCleanup(self.patch_revert.stop)

        rc.PRETEND = True
        self.execute_patch = mock.patch.object(rc, "execute")
        self.mock_execute = self.execute_patch.start()
        self.addCleanup(self.execute_patch.stop)
        self._fake_counter = 0

    def _create_live_subvolumes(self):
        for subvol in rc.OVERLAY_SUBVOLUMES:
            os.makedirs(os.path.join(rc.OVERLAY_DIR, subvol))

    def _fake_name(self, tag: str) -> str:
        self._fake_counter += 1
        return f"2026-07-24_{self._fake_counter:04d}_{tag}"

    def _make_namespace(self, action: str, **kwargs) -> mock.Mock:
        ns = mock.Mock()
        ns.action = action
        for k, v in kwargs.items():
            setattr(ns, k, v)
        return ns

    @mock.patch("regicide_update.cli_update.subprocess.call")
    def test_run_pacman_builds_pacman_command(self, mock_call):
        mock_call.return_value = 0
        rc.PRETEND = False
        code = cli_update.run_pacman("-Su")
        self.assertEqual(code, 0)
        mock_call.assert_called_once_with(["pacman", "-Su"])

    @mock.patch("regicide_update.cli_update.subprocess.call")
    @mock.patch("regicide_update.snapshots.create_snapshot_set")
    def test_transaction_creates_pre_and_post_snapshots_on_success(
        self, mock_create, mock_call
    ):
        mock_call.return_value = 0
        mock_create.side_effect = [self._fake_name("pre_upgrade"), self._fake_name("post_upgrade")]
        args = self._make_namespace("upgrade", no_rollback=False)
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_upgrade(args)
        self.assertEqual(ctx.exception.code, 0)
        self.assertEqual(mock_create.call_count, 2)

    @mock.patch("regicide_update.cli_update.subprocess.call")
    @mock.patch("regicide_update.snapshots.create_snapshot_set")
    @mock.patch("regicide_update.snapshots.set_revert")
    def test_transaction_schedules_revert_on_failure(
        self, mock_set_revert, mock_create, mock_call
    ):
        pre = self._fake_name("pre_upgrade")
        mock_call.return_value = 1
        mock_create.return_value = pre
        args = self._make_namespace("install", packages=["firefox"], no_rollback=False)
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_install(args)
        self.assertEqual(ctx.exception.code, 1)
        mock_set_revert.assert_called_once_with(pre)

    @mock.patch("regicide_update.cli_update.subprocess.call")
    @mock.patch("regicide_update.snapshots.create_snapshot_set")
    @mock.patch("regicide_update.snapshots.set_revert")
    def test_transaction_skips_revert_when_no_rollback_flag_set(
        self, mock_set_revert, mock_create, mock_call
    ):
        mock_call.return_value = 1
        mock_create.return_value = self._fake_name("pre_upgrade")
        args = self._make_namespace("remove", packages=["firefox"], no_rollback=True)
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_remove(args)
        self.assertEqual(ctx.exception.code, 1)
        mock_set_revert.assert_not_called()

    @mock.patch("regicide_update.cli_update.subprocess.call")
    def test_cmd_sync_runs_pacman_sync(self, mock_call):
        mock_call.return_value = 0
        args = self._make_namespace("sync")
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_sync(args)
        self.assertEqual(ctx.exception.code, 0)
        mock_call.assert_called_once_with(["pacman", "-Sy"])

    @mock.patch("regicide_update.cli_update.subprocess.call")
    def test_cmd_search_runs_pacman_search(self, mock_call):
        mock_call.return_value = 0
        args = self._make_namespace("search", query="firefox")
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_search(args)
        self.assertEqual(ctx.exception.code, 0)
        mock_call.assert_called_once_with(["pacman", "-Ss", "firefox"])

    @mock.patch("regicide_update.cli_update.subprocess.call")
    @mock.patch("os.geteuid", return_value=0)
    def test_main_requires_arguments(self, _mock_root, mock_call):
        mock_call.return_value = 0
        with self.assertRaises(SystemExit) as ctx:
            cli_update.main()
        self.assertEqual(ctx.exception.code, 2)


class KernelDetectionTests(unittest.TestCase):
    def test_transaction_mentions_kernel_matches_arch_kernel_packages(self):
        for pkg in ("linux", "linux-lts", "linux-zen", "linux-aarch64"):
            self.assertTrue(cli_update._transaction_mentions_kernel([pkg]))
        self.assertTrue(cli_update._transaction_mentions_kernel(["core/linux"]))
        self.assertFalse(cli_update._transaction_mentions_kernel(["firefox"]))
        self.assertFalse(cli_update._transaction_mentions_kernel([]))

    def test_kernel_changed_since_initramfs_true_when_no_initramfs(self):
        fake_stat = mock.Mock()
        fake_stat.st_mtime = 1000.0
        with mock.patch("regicide_update.cli_update.os.stat", return_value=fake_stat):
            with mock.patch("regicide_update.cli_update.glob.glob", return_value=[]):
                self.assertTrue(cli_update._kernel_changed_since_initramfs("6.9.0-arch1-1"))

    def test_kernel_changed_since_initramfs_compares_mtimes(self):
        modules_stat = mock.Mock()
        modules_stat.st_mtime = 2000.0
        initramfs = "/boot/initramfs-linux.img"
        with mock.patch("regicide_update.cli_update.os.stat", return_value=modules_stat):
            with mock.patch(
                "regicide_update.cli_update.glob.glob", return_value=[initramfs]
            ):
                with mock.patch(
                    "regicide_update.cli_update.os.path.getmtime", return_value=1000.0
                ):
                    self.assertTrue(
                        cli_update._kernel_changed_since_initramfs("6.9.0-arch1-1")
                    )
                with mock.patch(
                    "regicide_update.cli_update.os.path.getmtime", return_value=3000.0
                ):
                    self.assertFalse(
                        cli_update._kernel_changed_since_initramfs("6.9.0-arch1-1")
                    )

    def test_kernel_changed_since_initramfs_false_when_modules_missing(self):
        self.assertFalse(cli_update._kernel_changed_since_initramfs("0.0.0-nonexistent"))


class MaybeRefreshBootloaderTests(unittest.TestCase):
    def test_noop_when_no_kernel_installed(self):
        with mock.patch.object(cli_update, "_latest_kernel_version", return_value=None):
            with mock.patch.object(rc, "execute") as mock_execute:
                cli_update.maybe_refresh_bootloader(["linux"])
        mock_execute.assert_not_called()

    def test_noop_when_kernel_untouched_and_initramfs_current(self):
        with mock.patch.object(cli_update, "_latest_kernel_version", return_value="6.9.0-arch1-1"):
            with mock.patch.object(
                cli_update, "_kernel_changed_since_initramfs", return_value=False
            ):
                with mock.patch.object(rc, "execute") as mock_execute:
                    cli_update.maybe_refresh_bootloader(["firefox"])
        mock_execute.assert_not_called()

    def test_runs_mkinitcpio_when_kernel_package_in_transaction(self):
        with mock.patch.object(cli_update, "_latest_kernel_version", return_value="6.9.0-arch1-1"):
            with mock.patch.object(rc, "execute") as mock_execute:
                cli_update.maybe_refresh_bootloader(["linux"])
        mock_execute.assert_called_once_with("mkinitcpio", ["-P"])

    def test_runs_mkinitcpio_when_initramfs_older_than_modules(self):
        with mock.patch.object(cli_update, "_latest_kernel_version", return_value="6.9.0-arch1-1"):
            with mock.patch.object(
                cli_update, "_kernel_changed_since_initramfs", return_value=True
            ):
                with mock.patch.object(rc, "execute") as mock_execute:
                    cli_update.maybe_refresh_bootloader([])
        mock_execute.assert_called_once_with("mkinitcpio", ["-P"])

    @mock.patch("regicide_update.cli_update.subprocess.call")
    @mock.patch("regicide_update.snapshots.create_snapshot_set")
    @mock.patch("regicide_update.cli_update.maybe_refresh_bootloader")
    def test_transaction_passes_packages_to_bootloader_refresh(
        self, mock_refresh, mock_create, mock_call
    ):
        mock_call.return_value = 0
        mock_create.side_effect = ["pre_install", "post_install"]
        ns = mock.Mock()
        ns.action = "install"
        ns.packages = ["linux"]
        ns.no_rollback = False
        with self.assertRaises(SystemExit) as ctx:
            cli_update.cmd_install(ns)
        self.assertEqual(ctx.exception.code, 0)
        mock_refresh.assert_called_once_with(["linux"])


if __name__ == "__main__":
    unittest.main()
