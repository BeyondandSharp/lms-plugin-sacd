package Plugins::SACDPlayer::Formats;

# Install our tag readers on top of LMS's built-in DSD support.  The core
# streaming classes are intentionally left in place: our subclasses inherit
# them, so native DSF/DFF playback and seeking continue to work.

use strict;
use warnings;

use Plugins::SACDPlayer::Formats::DSF;
use Plugins::SACDPlayer::Formats::DFF;

sub install {
    my $class = shift;

    return 0 unless eval { require Slim::Formats; Slim::Formats->init; 1 };

    $Slim::Formats::tagClasses{dsf} = 'Plugins::SACDPlayer::Formats::DSF';
    $Slim::Formats::tagClasses{dff} = 'Plugins::SACDPlayer::Formats::DFF';

    # Force a reload if core already resolved these types.
    delete $Slim::Formats::loadedTagClasses{$_} for qw(dsf dff);

    return 1;
}

sub install_iso {
    my $class = shift;
    return 0 unless eval { require Slim::Music::Info; 1 };
    # ISO support is intentionally not enabled in 0.1.0.  The method exists
    # so a future release can add the type without changing Plugin.pm.
    return 0;
}

1;
