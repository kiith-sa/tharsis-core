#!/bin/sh
rm -rf doc
mkdir -p doc
mkdir -p docsrc/_build
cd docsrc
make html
cp -r _build/html/* ../doc
cp _build/html/index.html _build/html/contents.html
rm -r _build
cd ../
hmod
