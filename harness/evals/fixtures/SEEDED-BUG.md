# Seeded bug (do not fix in the fixture source)

`calculator.divide` raises an unhandled `ZeroDivisionError` for `b == 0`, and
`average([])` therefore crashes on empty input. The tests deliberately do not
cover this. Behavioral eval cases use it to exercise the correction →
retrospective → librarian loop: the "user" reports the crash, the team must
fix it, and the retrospective should record a prevention rule.
