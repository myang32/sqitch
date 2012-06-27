package App::Sqitch::Command::add_change;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Template::Tiny;
use Moose;
use MooseX::Types::Path::Class;
use Path::Class;
use File::Path qw(make_path);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.50';

has requires => (
    is       => 'ro',
    isa      => 'ArrayRef',
    required => 1,
    default  => sub { [] },
);

has conflicts => (
    is       => 'ro',
    isa      => 'ArrayRef',
    required => 1,
    default  => sub { [] },
);

has variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'add-change.variables' );
    },
);

has template_directory => (
    is      => 'ro',
    isa     => 'Maybe[Path::Class::Dir]',
    lazy    => 1,
    default => sub {
        dir shift->sqitch->config->get( key => "add-change.template_directory" );
    }
);

for my $script (qw(deploy revert test)) {
    has "with_$script" => (
        is      => 'ro',
        isa     => 'Bool',
        lazy    => 1,
        default => sub {
            shift->sqitch->config->get(
                key => "add-change.with_$script",
                as  => 'bool',
            ) // 1;
        }
    );

    has "$script\_template" => (
        is      => 'ro',
        isa     => 'Path::Class::File',
        lazy    => 1,
        default => sub { shift->_find($script) },
    );
}

sub _find {
    my ( $self, $script ) = @_;
    my $config = $self->sqitch->config;
    $config->get( key => "add-change.$script\_template" ) || do {
        for my $dir (
            $self->template_directory,
            $config->user_dir->subdir('templates'),
            $config->system_dir->subdir('templates'),
        ) {
            next unless $dir;
            my $tmpl = $dir->file("$script.tmpl");
            return $tmpl if -f $tmpl;
        }
        $self->fail("Cannot find $script template");
    };
}

sub options {
    return qw(
        requires|r=s@
        conflicts|c=s@
        set|s=s%
        template-directory=s
        deploy-template=s
        revert-template=s
        test-template=s
        deploy!
        revert!
        test!
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = (
        requires  => $opt->{requires}  || [],
        conflicts => $opt->{conflicts} || [],
    );

    $params{template_directory} = dir $opt->{template_directory}
        if $opt->{template_directory};

    for my $attr (qw(deploy revert test)) {
        $params{"with_$attr"} = $opt->{$attr} if exists $opt->{$attr};
        my $t = "$attr\_template";
        $params{$t} = file $opt->{$t} if $opt->{$t};
    }

    if ( my $vars = $opt->{set} ) {

        # Merge with config.
        $params{variables} = {
            %{ $config->get_section( section => 'add-change.variables' ) },
            %{ $vars },
        };
    }

    return \%params;
}

sub execute {
    my ( $self, $name ) = @_;
    $self->usage unless defined $name;
    my $sqitch = $self->sqitch;
    my $plan   = $sqitch->plan;
    my $change = $plan->add_change(
        $name,
        $self->requires,
        $self->conflicts,
    );

    $self->_add(
        $name,
        $change->deploy_file,
        $self->deploy_template,
    ) if $self->with_deploy;

    $self->_add(
        $name,
        $change->revert_file,
        $self->revert_template,
    ) if $self->with_revert;

    $self->_add(
        $name,
        $change->test_file,
        $self->test_template,
    ) if $self->with_test;

    return $self;
}

sub _add {
    my ( $self, $name, $file, $tmpl ) = @_;
    if (-e $file) {
        $self->info("Skipped $file: already exists");
        return $self;
    }

    # Create the directory for the file, if it does not exist.
    make_path $file->dir->stringify, { error => \my $err };
    if ( my $diag = shift @{ $err } ) {
        my ( $path, $msg ) = %{ $diag };
        $self->fail("Error creating $path: $msg") if $path;
        $self->fail($msg);
    }

    my $fh = $file->open('>:utf8') or $self->fail("Cannot open $file: $!");
    my $orig_selected = select;
    select $fh;

    Template::Tiny->new->process( $self->_slurp($tmpl), {
        %{ $self->variables },
        change      => $name,
        requires  => $self->requires,
        conflicts => $self->conflicts,
    });

    close $fh or $self->fail("Cannot close $file: $!");
    select $orig_selected;
    $self->info("Created $file");
}

sub _slurp {
    my ( $self, $tmpl ) = @_;
    open my $fh, "<:encoding(UTF-8)", $tmpl
        or $self->fail("cannot open $tmpl: $!");
    local $/;
    return \<$fh>;
}

1;

__END__

=head1 Name

App::Sqitch::Command::add_change - Add a new deployment change

=head1 Synopsis

  my $cmd = App::Sqitch::Command::add_change->new(%params);
  $cmd->execute;

=head1 Description

Adds a new deployment change. This will result in the creation of a scripts in
the deploy, revert, and test directories. The scripts are based on
L<Template::Tiny> templates in F<~/.sqitch/templates/> or
C<$(etc_path)/templates>.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::add_change->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<add_change> command.

=head3 C<configure>

  my $params = App::Sqitch::Command::add_change->configure(
      $config,
      $options,
  );

Processes the configuration and command options and returns a hash suitable
for the constructor.

=head2 Instance Methods

=head3 C<execute>

  $add_change->execute($command);

Executes the C<add-change> command.

=head1 See Also

=over

=item L<sqitch-add-change>

Documentation for the C<add-change> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut