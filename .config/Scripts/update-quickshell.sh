#!/usr/bin/env bash

git fetch quickshell_upstream main
git branch -D quickshell_upstream_main
git checkout -b quickshell_upstream_main quickshell_upstream/main
git subtree split -P dots/.config/quickshell -b quickshell_subfolder
git checkout master
git subtree merge --prefix=.config/quickshell quickshell_subfolder
