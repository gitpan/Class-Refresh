package Class::Refresh;
BEGIN {
  $Class::Refresh::AUTHORITY = 'cpan:DOY';
}
{
  $Class::Refresh::VERSION = '0.05';
}
use strict;
use warnings;
# ABSTRACT: refresh your classes during runtime

use Class::Unload;
use Class::Load;
use Try::Tiny;


our %CACHE;

sub import {
    my $package = shift;
    my %opts = @_;

    if ($opts{track_require}) {
        require Devel::OverrideGlobalRequire;
        require B;
        Devel::OverrideGlobalRequire::override_global_require(sub {
            my $next = shift;
            my ($file) = @_;

            my $ret = $next->();

            $package->_update_cache_for($file)
                # require v5.8.1;
                unless ref(\$file) eq 'VSTRING'
                # require 5.008001;
                || !(B::svref_2object(\$file)->FLAGS & B::SVf_POK());

            return $ret;
        });
    }
}


sub refresh {
    my $class = shift;

    $class->refresh_module($_) for $class->modified_modules;
}


sub modified_modules {
    my $class = shift;

    my @ret;
    for my $file (keys %CACHE) {
        # refresh files that are in our
        # %CACHE but not in %INC
        push @ret, $class->_file_to_mod($file)
            if (!$INC{$file});
    }

    for my $file (keys %INC) {
        if (exists $CACHE{$file}) {
            push @ret, $class->_file_to_mod($file)
                if $class->_mtime($file) ne $CACHE{$file};
        }
        else {
            $class->_update_cache_for($file);
        }
    }

    return @ret;
}


sub refresh_module {
    my $class = shift;
    my ($mod) = @_;
    $mod = $class->_file_to_mod($mod);

    my @to_refresh = grep { exists $INC{ $class->_mod_to_file($_) } }
                          $class->_dependent_modules($mod);

    $class->unload_module($_) for @to_refresh;
    $class->load_module($_) for @to_refresh;
}


sub unload_module {
    my $class = shift;
    my ($mod) = @_;
    $mod = $class->_file_to_mod($mod);

    Class::Unload->unload($mod);

    if (Class::Load::is_class_loaded('Class::MOP')) {
        Class::MOP::remove_metaclass_by_name($mod);
    }

    $class->_clear_cache_for($mod);
}


sub load_module {
    my $class = shift;
    my ($mod) = @_;
    $mod = $class->_file_to_mod($mod);

    try {
        Class::Load::load_class($mod);
    }
    catch {
        die $_;
    }
    finally {
        $class->_update_cache_for($mod);
    };
}

sub _dependent_modules {
    my $class = shift;
    my ($mod) = @_;
    $mod = $class->_file_to_mod($mod);

    return ($mod) unless Class::Load::is_class_loaded('Class::MOP');

    my $meta = Class::MOP::class_of($mod);

    return ($mod) unless $meta;

    if ($meta->isa('Class::MOP::Class')) {
        # attribute cloning (has '+foo') means that we can't skip refreshing
        # mutable classes
        return (
            # NOTE: this order is important!
            $mod,
            map { $class->_dependent_modules($_) }
                ($meta->subclasses,
                 # XXX: metacircularity? what if $class is Class::MOP::Class?
                 ($mod->isa('Class::MOP::Class')
                     ? (map { $_->name }
                            grep { $_->isa($mod) }
                                 Class::MOP::get_all_metaclass_instances())
                     : ())),
        );
    }
    elsif ($meta->isa('Moose::Meta::Role')) {
        return (
            $mod,
            map { $class->_dependent_modules($_) } $meta->consumers,
        );
    }
    else {
        die "Unknown metaclass: $meta";
    }
}

sub _update_cache_for {
    my $class = shift;
    my ($file) = @_;
    $file = $class->_mod_to_file($file);
    $CACHE{$file} = $class->_mtime($file);
}

sub _clear_cache_for {
    my $class = shift;
    my ($file) = @_;
    $file = $class->_mod_to_file($file);

    delete $CACHE{$file};
}

sub _mtime {
    my $class = shift;
    my ($file) = @_;
    $file = $class->_mod_to_file($file);
    return 1 if !$INC{$file};
    return join ' ', (stat($INC{$file}))[1, 7, 9];
}

sub _file_to_mod {
    my $class = shift;
    my ($file) = @_;

    return $file unless $file =~ /\.pm$/;

    my $mod = $file;
    $mod =~ s{\.pm$}{};
    $mod =~ s{/}{::}g;

    return $mod;
}

sub _mod_to_file {
    my $class = shift;
    my ($mod) = @_;

    return $mod unless $mod =~ /^\w+(?:::\w+)*$/;

    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    return $file;
}


1;

__END__

=pod

=head1 NAME

Class::Refresh - refresh your classes during runtime

=head1 VERSION

version 0.05

=head1 SYNOPSIS

  use Class::Refresh;
  use Foo;

  Class::Refresh->refresh;

  # edit Foo.pm

  Class::Refresh->refresh; # changes in Foo.pm are applied

=head1 DESCRIPTION

During development, it is fairly common to cycle between writing code and
testing that code. Generally the testing happens within the test suite, but
frequently it is more convenient to test things by hand when tracking down a
bug, or when doing some exploratory coding. In many situations, however, this
becomes inconvenient - for instance, in a REPL, or in a stateful web
application, restarting from the beginning after every code change can get
pretty tedious. This module allows you to reload your application classes on
the fly, so that the code/test cycle becomes a lot easier.

This module takes a hash of import arguments, which can include:

=over 4

=item track_require

  use Class::Refresh track_require => 1;

If set, a C<require()> hook will be installed to track modules which are
loaded. This will make the list of modules to reload when C<refresh> is called
more accurate, but may cause issues with other modules which hook into
C<require> (since the hook is global).

=back

This module has several limitations, due to reloading modules in this way being
an inherently fragile operation. Therefore, this module is recommended for use
only in development environments - it should not be used for reloading things
in production.

It makes several assumptions about how code is structured that simplify the
logic involved quite a bit, and make it more reliable when those assumptions
hold, but do make it inappropriate for use in certain cases. For instance, this
module is named C<Class::Refresh> for a reason: it is only intended for
refreshing classes, where each file contains a single namespace, and each
namespace corresponds to a single file, and all function calls happen through
method dispatch. Unlike L<Module::Refresh>, which makes an effort to track the
files where subs were defined, this module assumes that refreshing a class
means wiping out everything in the class's namespace, and reloading the file
corresponding to that class. If your code includes multiple files that all load
things into a common namespace, or defines multiple classes in a single file,
this will likely not work.

=head1 METHODS

=head2 refresh

The main entry point to the module. The first call to C<refresh> populates a
cache of modification times for currently loaded modules, and subsequent calls
will refresh any classes which have changed since the previous call.

=head2 modified_modules

Returns a list of modules which have changed since the last call to C<refresh>.

=head2 refresh_module $mod

This method calls C<unload_module> and C<load_module> on C<$mod>, as well as on
any classes that depend on C<$mod> (for instance, subclasses if C<$mod> is a
class, or classes that consume C<$mod> if C<$mod> is a role). This ensures that
all of your classes are consistent, even when dealing with things like
immutable L<Moose> classes.

=head2 unload_module $mod

Unloads C<$mod>, using L<Class::Unload>.

=head2 load_module $mod

Loads C<$mod>, using L<Class::Load>.

=head1 CAVEATS

=over 4

=item Refreshing modules may miss modules which have been externally loaded since the last call to refresh

This is because it's not easily possible to tell if a module has been modified
since it was loaded, if we haven't seen it so far. A workaround for this may be
to set the C<track_require> option in the import arguments (see above),
although this comes with its own set of caveats (since it is global behavior).

=item Global variable accesses and function calls may not work as expected

Perl resolves accesses to global variables and functions in other packages at
compile time, so if the package is later reloaded, changes to those will not be
noticed. As mentioned above, this module is intended for refreshing B<classes>.

=item File modification times have a granularity of one second

If you modify a file and then immediately call C<refresh> and then immediately
modify it again, the modification may not be seen on the next call to
C<refresh>. Note however that file size and inode number are also compared, so
it still may be seen, depending on if either of those two things changed.

=item Tracking modules which C<use> a given module isn't possible

For instance, modifying a L<Moose::Exporter> module which is used in a class
won't cause the class to be refreshed, even if the change to the exporter would
cause a change in the class's metaclass.

=item Classes which build themselves differently based on the state of other classes may not work properly

This module attempts to handle several cases of this sort for L<Moose> classes
(modifying a class will refresh all of its subclasses, modifying a role will
refresh all classes and roles which consume that role, modifying a metaclass
will refresh all classes whose metaclass is an instance of that metaclass), but
it's not a problem that's solvable in the general case.

=back

=head1 BUGS

=over 4

=item Reloading classes when their metaclass is modified doesn't quite work yet

This will require modifications to Moose to support properly.

=item Tracking changes to metaclasses other than the class metaclass isn't implemented yet

=item Metacircularity probably has issues

Refreshing a class which is its own metaclass will likely break.

=back

Please report any bugs through RT: email
C<bug-class-refresh at rt.cpan.org>, or browse to
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Class-Refresh>.

=head1 SEE ALSO

L<Module::Refresh>

=head1 SUPPORT

You can find this documentation for this module with the perldoc command.

    perldoc Class::Refresh

You can also look for information at:

=over 4

=item * MetaCPAN

L<https://metacpan.org/release/Class-Refresh>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Class-Refresh>

=item * Github

L<https://github.com/doy/class-refresh>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Class-Refresh>

=back

=head1 CREDITS

This module was based in large part on L<Module::Refresh> by Jesse Vincent.

=head1 AUTHOR

Jesse Luehrs <doy at tozt dot net>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Jesse Luehrs.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
