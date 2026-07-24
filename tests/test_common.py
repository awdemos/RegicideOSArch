import unittest
from regicide_update import common as rc


class CommonTests(unittest.TestCase):
    def test_colours(self):
        self.assertTrue(rc.Colours.red.startswith("\033["))

    def test_overlay_subvolumes(self):
        self.assertEqual(rc.OVERLAY_SUBVOLUMES, ("etc", "var", "usr"))


if __name__ == "__main__":
    unittest.main()
