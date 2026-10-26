use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# The user-visible and packaged plugin name is "SACD".  The Perl module,
# settings URL and preferences namespace intentionally keep the historical
# "SACDPlayer"/"plugin.sacdplayer" identifiers so existing settings and
# module references keep working.

my $root = "$Bin/..";

sub slurp {
    my ($rel) = @_;
    open my $fh, '<', "$root/$rel" or die "$rel: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

# --- display strings -------------------------------------------------------

my $strings = slurp('strings.txt');

my (%string, $key);
for my $line (split /\n/, $strings) {
    if ($line =~ /^([A-Z][A-Z0-9_]*)$/) {
        $key = $1;
        next;
    }
    if (defined $key && $line =~ /^\t(EN|ZH)\t(.*)$/) {
        $string{$key}{$1} = $2;
    }
}

is($string{PLUGIN_SACDPLAYER}{EN}, 'SACD', 'plugin display name (EN) is SACD');
is($string{PLUGIN_SACDPLAYER}{ZH}, 'SACD', 'plugin display name (ZH) is SACD');
is($string{PLUGIN_SACDPLAYER_SETTINGS}{EN}, 'SACD', 'settings display name (EN) is SACD');
is($string{PLUGIN_SACDPLAYER_SETTINGS}{ZH}, 'SACD', 'settings display name (ZH) is SACD');

unlike($strings, qr/SACD Player/, 'no "SACD Player" display string remains');
unlike($strings, qr/SACD 播放器/, 'no "SACD 播放器" display string remains');

# --- READMEs ---------------------------------------------------------------

my $readme = slurp('README.md');
like($readme, qr/^# SACD for Lyrion Music Server$/m, 'EN README title uses SACD');
unlike($readme, qr/SACD Player/, 'EN README no longer calls the plugin "SACD Player"');

my $readme_zh = slurp('README.zh-CN.md');
like($readme_zh, qr/^# SACD for Lyrion Music Server（中文说明）$/m,
    'ZH README title uses SACD');
unlike($readme_zh, qr/SACD 播放器/, 'ZH README no longer calls the plugin "SACD 播放器"');

# --- remaining display surfaces --------------------------------------------

my $install = slurp('install.xml.in');
like($install, qr{<name>PLUGIN_SACDPLAYER</name>}, 'string id PLUGIN_SACDPLAYER unchanged');
like($install, qr{<module>Plugins::SACDPlayer::Plugin</module>},
    'module Plugins::SACDPlayer::Plugin unchanged');
like($install, qr{<creator>SACD contributors</creator>}, 'creator uses the SACD product name');

my $repo = slurp('repo.xml.in');
like($repo, qr{<title>SACD</title>}, 'catalog title uses SACD');
like($repo, qr{<plugin name="SACD"}, 'catalog plugin name SACD');

# --- compatibility identifiers that must not be renamed --------------------

like(slurp('lib/Plugins/SACDPlayer/PlayerSettings.pm'),
    qr{plugins/SACDPlayer/settings/player\.html},
    'settings URL plugins/SACDPlayer unchanged');
like(slurp('lib/Plugins/SACDPlayer/Plugin.pm'),
    qr{logger\('plugin\.sacdplayer'\)},
    'prefs/log namespace plugin.sacdplayer unchanged');
like(slurp('Makefile'), qr{^DIST\s*:=\s*dist/SACD$}m,
    'install folder dist/SACD');
like(slurp('tools/sync-version.pl'), qr/SACD-\$version\.zip/,
    'release asset SACD-<version>.zip');
ok(-d "$root/lib/Plugins/SACDPlayer", 'module directory Plugins/SACDPlayer unchanged');

done_testing;
