package Plugins::SACDPlayer::Formats::DFF;

# Tag-reader override for DSDIFF.  DST files are parsed by our header-only
# parser; DSD files inherit LMS's native streaming/seeking methods.

use strict;
use warnings;

use base qw(Slim::Formats::DFF);

use Plugins::SACDPlayer::TagReader;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.sacdplayer');

sub _opts {
    my $mb = $prefs->get('max_tag_size_mb') || 32;
    return {
        max_tag_size => $mb * 1024 * 1024,
        tag_fallback => $prefs->get('tag_fallback') || 'auto',
        ffprobe      => $prefs->get('ffprobe'),
    };
}

sub getTag {
    my ($class, $file) = @_;
    return undef unless $file;
    my $tags = Plugins::SACDPlayer::TagReader->read($file, %{ _opts() });
    return undef unless $tags;
    # LMS's scanner sanitises every tag value; private hash/array metadata
    # (used by our routing hooks) must never leak into that pass.
    delete $tags->{$_} for grep { /^_/ } keys %$tags;
    return $tags;
}

sub getCoverArt {
    my ($class, $file) = @_;
    return undef unless $file;
    my $path = $file;
    if ($path =~ m{^file://}) {
        eval { require Slim::Utils::Misc; $path = Slim::Utils::Misc::pathFromFileURL($path); 1 };
        $path =~ s/^file:\/\///;
    }
    $path =~ s/#.*$//;
    my $pic = Plugins::SACDPlayer::TagReader->get_cover_art($path, %{ _opts() });
    return $pic && $pic->{data} ? $pic->{data} : undef;
}

# The core DFF implementation calls Audio::Scan, which rejects DST.  DST is
# always transcoded by our helper, so byte-based stream helpers are not used.
sub getInitialAudioBlock {
    my ($class, $fh, $track) = @_;
    if ($track && _track_is_dst($track)) {
        return '';
    }
    return $class->SUPER::getInitialAudioBlock($fh, $track);
}

sub findFrameBoundaries {
    my ($class, $fh, $offset, $time, $track) = @_;
    if ($track && _track_is_dst($track)) {
        return 0;
    }
    return $class->SUPER::findFrameBoundaries($fh, $offset, $time);
}

sub canSeek {
    my ($class, $url) = @_;
    my $path = _path($url);
    if ($path) {
        my $tags = Plugins::SACDPlayer::TagReader->read($path);
        return 0 if $tags && $tags->{_sacd} && $tags->{_sacd}{is_dst};
    }
    return 1;
}

sub _track_is_dst {
    my ($track) = @_;
    my $url = eval { $track->url } || '';
    my $path = _path($url);
    return 0 unless $path;
    my $tags = Plugins::SACDPlayer::TagReader->read($path);
    return $tags && $tags->{_sacd} && $tags->{_sacd}{is_dst} ? 1 : 0;
}

sub _path {
    my ($url) = @_;
    return undef unless defined $url;
    $url =~ s/#.*$//;
    $url =~ s/^file:\/\///;
    $url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $url;
}

1;
