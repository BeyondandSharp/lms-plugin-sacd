package Slim::Utils::Log;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(logger);
sub logger { return bless {}, 'Slim::Utils::Log::Obj' }
package Slim::Utils::Log::Obj;
sub debug { 1 } sub info { 1 } sub warn { 1 } sub error { 1 } sub is_debug { 0 }
1;
