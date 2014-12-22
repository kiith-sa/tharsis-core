#!/bin/sh
mkdir -p doc/html
rm -rf doc/html
cd docsrc
make html
cp -r _build/html ../doc/html
