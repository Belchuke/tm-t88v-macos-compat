# TM-T88V macOS Compatibility Layer

A native macOS compatibility layer for Epson TM-T88V USB receipt printers.

The project exists to replace Epson's legacy Intel-based macOS printing components with a modern Apple Silicon-native solution while preserving standard macOS printing support for existing applications.

## Goal

Preserve the existing workflow:

Application
→ macOS Print
→ EPSON TM-T88V

while replacing the legacy Epson driver path with:

macOS Print
→ Local IPP printer
→ Native compatibility service
→ ESC/POS
→ USB
→ Epson TM-T88V

No changes should be required in applications that already use the built-in macOS printing system.
