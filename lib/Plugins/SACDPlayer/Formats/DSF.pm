package Plugins::SACDPlayer::Formats::DSF;

# Tag-reader override for DSF.  Streaming methods are inherited from LMS so
# native DSF playback and seeking keep working exactly as before.

use strict;
use warnings;

use base qw(Slim::Formats::DSF);

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

1;
