#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;

my ($version, $release_base, $tag_prefix, $output_dir);
GetOptions(
    'version=s'      => \$version,
    'release-base=s' => \$release_base,
    'tag-prefix=s'   => \$tag_prefix,
    'output-dir=s'   => \$output_dir,
) or die "usage: $0 --version X.Y.Z [--release-base URL] [--tag-prefix v] [--output-dir DIR]\n";

$version //= do {
    open my $fh, '<', 'VERSION' or die "VERSION: $!\n";
    scalar <$fh>;
};
chomp $version;
$version =~ s/^\s+|\s+$//g;
die "version must look like X.Y.Z\n" unless $version =~ /^\d+\.\d+\.\d+$/;

$release_base //= 'https://git.fchscastle.com/BeyondandSharp/lms-plugin-sacd/releases/download';
$release_base =~ s{/+$}{};
$tag_prefix //= 'v';
$output_dir //= 'build';

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub write_file {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "$path: $!\n";
    print {$fh} $text;
    close $fh;
}

my $install = read_file('install.xml.in');
$install =~ s{\@VERSION\@}{$version}g;
die "install.xml.in: \@VERSION\@ not found\n" unless $install =~ /<version>\Q$version\E<\/version>/;
mkdir $output_dir unless -d $output_dir;
write_file("$output_dir/install.xml", $install);

my $repo = read_file('repo.xml.in');
my $url = "$release_base/$tag_prefix$version/SACDPlayer-$version.zip";
$repo =~ s{\@VERSION\@}{$version}g;
$repo =~ s{\@RELEASE_URL\@}{$url}g;
die "repo.xml.in: placeholders not found\n" unless $repo =~ /version="\Q$version\E"/ && $repo =~ /\Q$url\E/;
write_file("$output_dir/repo.xml", $repo);

print "version: $version\n";
print "repo url: $url\n";
print "rendered: $output_dir/install.xml, $output_dir/repo.xml\n";
