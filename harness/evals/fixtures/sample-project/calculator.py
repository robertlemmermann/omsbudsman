"""A tiny calculator module — the fixture's product code."""


def add(a, b):
    return a + b


def subtract(a, b):
    return a - b


def multiply(a, b):
    return a * b


def divide(a, b):
    return a / b


def average(values):
    return divide(sum(values), len(values))
