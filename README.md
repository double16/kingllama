# King Llama

A macOS app to give local models all the GPU.

![logo](logo.png)

Many programs are using GPU: browsers, Apple services, etc. When you run a local
model using Ollama, Llama.cpp, etc., you want all the GPU! This app will monitor
for other processes using the GPU and suspend or stop them.

This app does questionable things to get GPU usage because it isn't exposed in
a public API.

1. Private Metal libraries.
2. Scraping the Activity Monitor UI.

Scraping Activity Monitor requires Accessibility permissions.

