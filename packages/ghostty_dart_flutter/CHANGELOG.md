## 0.0.1-dev

- Unreleased. `VtTerminalView` renders a `VtTerminalController`'s terminal
  (cached row pictures, cursor overlay, padding, background opacity) and
  takes keyboard (legacy and Kitty encoding, shell-safe shortcuts), IME and
  soft-keyboard text, mouse reports, selection, wheel and touch scrolling,
  and resizes the terminal to fit. While accessibility is on it exposes the
  visible text as a semantics node, with optional announcements of new
  output. `VtTerminalKeyToolbar` adds Esc, Ctrl, Alt, Tab and arrow keys for
  touch screens.
