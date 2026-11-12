@echo off
rem The tuning menu: basalt-probe, A/B benches and the config interview (basalt-helper.ps1).
rem It asks which GPU and model to use; docs/probe.md explains what the probe measures.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0basalt-helper.ps1"
