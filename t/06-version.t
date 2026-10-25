use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

my $version = slurp('VERSION');
$version =~ s/\s+//g;
like($version, qr/^\d+\.\d+\.\d+$/, 'VERSION is a semantic version');

# The tracked manifests are templates, not versioned copies.
my $install_tpl = slurp('install.xml.in');
like($install_tpl, qr/<version>\@VERSION\@<\/version>/, 'install.xml.in has a version placeholder');
unlike($install_tpl, qr/<version>\d+\.\d+\.\d+<\/version>/, 'install.xml.in contains no concrete version');

my $repo_tpl = slurp('repo.xml.in');
like($repo_tpl, qr/version="\@VERSION\@"/, 'repo.xml.in has a version placeholder');
like($repo_tpl, qr/<url>\@RELEASE_URL\@<\/url>/, 'repo.xml.in has a URL placeholder');

my $out = tempdir(CLEANUP => 1);
my $rc = system($^X, 'tools/sync-version.pl',
    '--version', $version,
    '--tag-prefix', 'v',
    '--output-dir', $out,
);
is($rc, 0, 'renderer succeeds');

my $install = slurp("$out/install.xml");
my ($install_version) = $install =~ m{<version>\s*([^<]+?)\s*</version>};
is($install_version, $version, 'rendered install.xml version matches VERSION');

my $repo = slurp("$out/repo.xml");
my ($repo_version) = $repo =~ m{<plugin\b[^>]*\bversion="([^"]+)"};
is($repo_version, $version, 'rendered repo.xml version matches VERSION');

my ($url) = $repo =~ m{<url>\s*([^<]+?)\s*</url>};
like($url, qr{/v\Q$version\E/SACDPlayer-\Q$version\E\.zip$},
    'rendered repo.xml URL points at the matching release asset');

done_testing;
