# --
# Kernel/Scheduler.pm - The otrs Scheduler Daemon
# Copyright (C) 2001-2011 OTRS AG, http://otrs.org/
# --
# $Id: Scheduler.pm,v 1.15 2011-02-23 03:50:59 cr Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Scheduler;

use strict;
use warnings;

use Kernel::System::VariableCheck qw(IsHashRefWithData IsStringWithData);
use Kernel::System::Scheduler::TaskManager;
use Kernel::Scheduler::TaskHandler;

use vars qw(@ISA $VERSION);
$VERSION = qw($Revision: 1.15 $) [1];

=head1 NAME

Kernel::Scheduler - otrs Scheduler lib

=head1 SYNOPSIS

All scheduler functions.

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object

    use Kernel::Config;
    use Kernel::System::Encode;
    use Kernel::System::Log;
    use Kernel::System::Main;
    use Kernel::System::DB;
    use Kernel::Scheduler;

    my $ConfigObject = Kernel::Config->new();
    my $EncodeObject = Kernel::System::Encode->new(
        ConfigObject => $ConfigObject,
    );
    my $LogObject = Kernel::System::Log->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
    );
    my $MainObject = Kernel::System::Main->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
    );
    my $DBObject = Kernel::System::DB->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        MainObject   => $MainObject,
    );
    my $SchedulerObject = Kernel::Scheduler->new(
        ConfigObject => $ConfigObject,
        LogObject    => $LogObject,
        DBObject     => $DBObject,
        MainObject   => $MainObject,
        EncodeObject => $EncodeObject,
    );

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # check needed objects
    for my $Object (qw(MainObject ConfigObject LogObject DBObject EncodeObject TimeObject)) {
        $Self->{$Object} = $Param{$Object} || die "Got no $Object!";
    }

    # create aditional objects
    $Self->{TaskManagerObject} = Kernel::System::Scheduler::TaskManager->new( %{$Self} );

    return $Self;
}

=item Run()

Find and dispatch a Task

    my $Result = $SchedulerObject->Run();

    $Result = 1                   # 0 or 1;

=cut

sub Run {
    my ( $Self, %Param ) = @_;

    # get all tasks
    my @TaskList = $Self->{TaskManagerObject}->TaskList();

    # if there are no task to execute return succesfull
    return 1 if !@TaskList;

    # get the task details
    TASKITEM:
    for my $TaskItem (@TaskList) {
        ;
        if ( !$TaskItem ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'Got invalid task list!',
            );

            # skip if can't get task
            next TASKITEM;
        }

        # delete task if no type is set
        if ( !$TaskItem->{Type} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Task $TaskItem->{ID} will be deleted bacause type is not set!",
            );
            $Self->{TaskManagerObject}->TaskDelete( ID => $TaskItem->{ID} );

            # skip if no task has no type
            next TASKITEM;
        }

        # do not execute if task is schedule for future
        my $SystemTime  = $Self->{TimeObject}->SystemTime();
        my $TaskDueTime = $Self->{TimeObject}->TimeStamp2SystemTime(
            String => $TaskItem->{DueTime},
        );
        next TASKITEM if ( $TaskDueTime gt $SystemTime );

        # get task data
        my %TaskData = $Self->{TaskManagerObject}->TaskGet( ID => $TaskItem->{ID} );
        if ( !%TaskData ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'Got invalid task data!',
            );
            $Self->{TaskManagerObject}->TaskDelete( ID => $TaskItem->{ID} );

            # skip if cant get task data
            next TASKITEM;
        }

        # create task handler object
        my $TaskHandlerObject = eval {
            Kernel::Scheduler::TaskHandler->new(
                %{$Self},
                TaskHandlerType => $TaskItem->{Type},
            );
        };

        # check if Task Handler object was created
        if ( !$TaskHandlerObject ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Can't create $TaskItem->{Type} task handler object! $@",
            );

            $Self->{TaskManagerObject}->TaskDelete( ID => $TaskItem->{ID} );

            # skip if can't create task handler
            next TASKITEM;
        }

        # call run method on task handler object
        my $TaskResult = $TaskHandlerObject->Run( Data => $TaskData{Data} );

        # skip if can't delete task
        next TASKITEM if !$Self->{TaskManagerObject}->TaskDelete( ID => $TaskItem->{ID} );

        # check if need to re-schedule
        if ( !$TaskResult->{Success} && $TaskResult->{ReSchedule} ) {

            # set new due time
            $TaskData{DueTime} = $TaskResult->{DueTime} || '';

            # set new task data if needed
            if ( $TaskResult->{Data} ) {
                $TaskData{Data} = $TaskResult->{Data}
            }

            # create a ne task
            my $TaskID = $Self->TaskRegister(%TaskData);

            # check if task was re scheduled successfuly
            if ( !$TaskID ) {
                $Self->{LogObject}->Log(
                    Priority => 'error',
                    Message  => "Can't re-schedule task",
                );
                next TASKITEM;
            }
            $Self->{LogObject}->Log(
                Priority => 'notice',
                Message  => "task is re-scheduled!",
            );
        }
    }

    return 1;
}

=item TaskRegister()

    my $TaskID = $SchedulerObject->TaskRegister(
        Type     => 'GenericInterface',
        DueTime  => '2006-01-19 23:59:59',          # optional (default current time)
        Data     => {                               # task data
            ...
        },
    );

=cut

sub TaskRegister {
    my ( $Self, %Param ) = @_;

    # check task type
    if ( !IsStringWithData( $Param{Type} ) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Got no Task Type with content!',
        );

        # retrun failure if no task type is sent
        return;
    }

    # check if task data is undefined
    if ( !defined $Param{Data} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Got undefined Task Data!',
        );

        # retrun error if task data is undefined
        return;
    }

    # register task
    my $TaskID = $Self->{TaskManagerObject}->TaskAdd(
        %Param,
    );

    # check if task was registered
    if ( !$TaskID ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Task could not be registered',
        );

        # retrun failure if task registration fails
        return;
    }

    # otherwise return the task ID
    return $TaskID;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

=head1 VERSION

$Revision: 1.15 $ $Date: 2011-02-23 03:50:59 $

=cut
