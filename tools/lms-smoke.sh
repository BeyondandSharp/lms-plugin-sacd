#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
echo "== Perl syntax (pure modules)"
perl -Ilib -c lib/Plugins/SACDPlayer/DFFParser.pm
perl -Ilib -c lib/Plugins/SACDPlayer/ID3.pm
perl -Ilib -c lib/Plugins/SACDPlayer/Rates.pm
perl -Ilib -c lib/Plugins/SACDPlayer/TagReader.pm
echo "== helper"
make -C helper/src test
echo "== unit tests"
prove -l -It/lib t
echo "Done. Install the plugin as Plugins/SACDPlayer and restart LMS."
