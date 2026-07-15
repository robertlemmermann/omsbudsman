import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import calculator


class CalculatorTest(unittest.TestCase):
    def test_add(self):
        self.assertEqual(calculator.add(2, 3), 5)

    def test_subtract(self):
        self.assertEqual(calculator.subtract(5, 3), 2)

    def test_multiply(self):
        self.assertEqual(calculator.multiply(4, 3), 12)

    def test_divide(self):
        self.assertEqual(calculator.divide(6, 3), 2)

    def test_average(self):
        self.assertEqual(calculator.average([1, 2, 3]), 2)


if __name__ == "__main__":
    unittest.main()
