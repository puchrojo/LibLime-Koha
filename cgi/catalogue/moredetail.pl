#!/usr/bin/env perl

# Copyright 2000-2003 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA


use strict;
use C4::Koha;
use CGI;
use C4::Biblio;
use C4::Items;
use C4::Branch;
use C4::Acquisition;
use C4::Output;             # contains gettemplate
use C4::Auth;
use C4::Serials;
use C4::Dates qw/format_date/;
use C4::Circulation;  # to use itemissues
use C4::Search;		# enabled_staff_search_views

my $query=new CGI;

# FIXME  subject is not exported to the template?
my $subject=$query->param('subject');

# if its a subject we need to use the subject.tmpl
my ($template, $loggedinuser, $cookie) = get_template_and_user({
    template_name   => ($subject? 'catalogue/subject.tmpl':
                      'catalogue/moredetail.tmpl'),
    query           => $query,
    type            => "intranet",
    authnotrequired => 0,
    flagsrequired   => {catalogue => '*'},
    });

# get variables

my $biblionumber=$query->param('biblionumber');
my $title=$query->param('title');
my $itemnumber=$query->param('itemnumber');
my $bi=$query->param('bi');
my $updatefail = $query->param('updatefail');
# $bi = $biblionumber unless $bi;
my $data=GetBiblioData($biblionumber);
my $dewey = $data->{'dewey'};

#coping with subscriptions
my $subscriptionsnumber = CountSubscriptionFromBiblionumber($biblionumber);

# FIXME Dewey is a string, not a number, & we should use a function
# $dewey =~ s/0+$//;
# if ($dewey eq "000.") { $dewey = "";};
# if ($dewey < 10){$dewey='00'.$dewey;}
# if ($dewey < 100 && $dewey > 10){$dewey='0'.$dewey;}
# if ($dewey <= 0){
#      $dewey='';
# }
# $dewey=~ s/\.$//;
# $data->{'dewey'}=$dewey;

my @results;
my $fw = GetFrameworkCode($biblionumber);
my @items= GetItemsInfo($biblionumber);
my $count=@items;
$data->{'count'}=$count;

my $ordernum = GetOrderNumber($biblionumber);
my $order = GetOrder($ordernum);
my $ccodes= GetKohaAuthorisedValues('items.ccode',$fw);
my $itemtypes = GetItemTypes;

# dealing w/ item ownership
my $restrict = C4::Context->preference('EditAllLibraries') ?undef:1;
my(@worklibs,%br);
if ($restrict) {
   use C4::Members;
   @worklibs = C4::Members::GetWorkLibraries(_borrower());
   $template->param('restrict'=>$restrict);
   my $branches = C4::Branch::GetBranches();
   my $tmp;
   foreach(@worklibs) { $br{$_} = 1 } # this is better than grep
}

$data->{'itemtypename'} = $itemtypes->{$data->{'itemtype'}}->{'description'};
$results[0]=$data;
($itemnumber) and @items = (grep {$_->{'itemnumber'} == $itemnumber} @items);
my $itemcount=0;
my $additemnumber;
my @tmpitems;
my $crval = C4::Context->preference('ClaimsReturnedValue');
my %avc = (
   itemlost => GetAuthValCode('items.itemlost',$fw),
   damaged  => GetAuthValCode('items.damaged' ,$fw),
   suppress => GetAuthValCode('items.suppress',$fw),
);
foreach(@{GetAuthorisedValues($avc{itemlost})}) {
   if ($$_{authorised_value} ~~ 1) {
      $template->param(charge_authval => $$_{lib});
   }
   elsif ($$_{authorised_value} ~~ $crval) {
      $template->param(claimsreturned_authval => $$_{lib});
   }
}
my @fail = qw(nocr nocr_notcharged nolc_noco);
foreach my $item (@items){
    $additemnumber = $item->{'itemnumber'} if (!$itemcount);
    $itemcount++;
    if ($$item{itemlost}) {
        if (my $lostitem = C4::LostItems::GetLostItem($$item{itemnumber})) {
            my $lostbor = C4::Members::GetMember($$lostitem{borrowernumber});
            $item->{lostby_date} = C4::Dates->new($$lostitem{date_lost},'iso')->output;
            $item->{lostby_name} = "$$lostbor{firstname} $$lostbor{surname}";
            $item->{lostby_borrowernumber} = $$lostitem{borrowernumber};
            $item->{lostby_cardnumber} = $$lostbor{cardnumber};
        }
    }
    if ($updatefail && ($$item{itemnumber} ~~ $itemnumber)) {
        $item->{"updatefail_$updatefail"} = 1;
        if ($updatefail ~~ 'nocr_charged') {
            my $oldiss = C4::Circulation::GetOldIssue($itemnumber);
            my $acc    = C4::Accounts::GetLine($query->param('oiborrowernumber'),$query->param('accountno'));
            my $accbor = C4::Members::GetMember($$acc{borrowernumber});
            $$item{"cr_oi_name"} = "$$accbor{firstname} $$accbor{surname}";
            $$item{"cr_oi_cardnumber"} = $$accbor{cardnumber};
            foreach(qw(returndate issuedate date_due)) {
               $$item{"cr_oi_$_"} = C4::Dates->new($$oldiss{$_},'iso')->output;
            }
            foreach(keys %$acc) {
               $$item{"cr_oi_$_"} = $$acc{$_};
            }
            foreach(qw(amount amountoutstanding)) {
               $$item{"cr_oi_$_"} = sprintf('%.02f',$$item{"cr_oi_$_"});
            }
        }
        if ($updatefail ~~ @fail) {
            my $oldiss = C4::Circulation::GetOldIssue($itemnumber) // {};
            if ($$oldiss{borrowernumber}) { # may be anonymised
               my $lastbor = C4::Members::GetMember($$oldiss{borrowernumber});
               $$item{lastbor_name} = "$$lastbor{firstname} $$lastbor{surname}";
               $$item{lastbor_returndate} = C4::Dates->new($$oldiss{returndate},'iso')->output;
               $$item{lastbor_borrowernumber} = $$oldiss{borrowernumber};
               $$item{lastbor_cardnumber}     = $$lastbor{cardnumber};
            }
        }
    }

    $item->{itemlostloop}    = GetAuthorisedValues($avc{itemlost},$item->{itemlost}) if $avc{itemlost};
    $item->{itemdamagedloop} = GetAuthorisedValues($avc{damaged}, $item->{damaged})  if $avc{damaged};
    $item->{itemsuppressloop}= GetAuthorisedValues($avc{suppress},$item->{suppress}) if $avc{suppress};
    $item->{itemstatusloop} = GetOtherItemStatus($item->{'otherstatus'});
    $item->{'collection'} = $ccodes->{$item->{ccode}};
    $item->{'itype'} = $itemtypes->{$item->{'itype'}}->{'description'}; 
    $item->{'replacementprice'}=sprintf("%.2f", $item->{'replacementprice'});
    $item->{'datelastborrowed'}= format_date($item->{'datelastborrowed'});
    $item->{'dateaccessioned'} = format_date($item->{'dateaccessioned'});
    $item->{'datelastseen'} = format_date($item->{'datelastseen'});
    $item->{'ordernumber'} = $ordernum;
    $item->{'booksellerinvoicenumber'} = $order->{'booksellerinvoicenumber'};
    $item->{'copyvol'} = $item->{'copynumber'};
    if ($item->{notforloantext} or $item->{itemlost} or $item->{damaged} or $item->{wthdrawn} or $item->{suppress}) {
        $item->{status_advisory} = 1;
    }

    if (C4::Context->preference("IndependantBranches")) {
        #verifying rights
        my $userenv = C4::Context->userenv();
        unless (($userenv->{'flags'} == 1) or ($userenv->{'branch'} eq $item->{'homebranch'})) {
                $item->{'nomod'}=1;
        }
    }

    $item->{'homebranchname'} = GetBranchName($item->{'homebranch'});
    $item->{'holdingbranchname'} = GetBranchName($item->{'holdingbranch'});
    if ($item->{'datedue'}) {
        $item->{'datedue'} = format_date($item->{'datedue'});
        $item->{'issue'}= 1;
    } else {
        $item->{'issue'}= 0;
    }

    # item ownership
    if ($restrict && !$br{$$item{homebranch}}) {
         $$item{notmine} = 1;
    }
    push @tmpitems, $item;
}

@items = @tmpitems;
$template->param(count => $data->{'count'},
	subscriptionsnumber => $subscriptionsnumber,
    subscriptiontitle   => $data->{title},
	C4::Search::enabled_staff_search_views,
);
$template->param(BIBITEM_DATA => \@results);
$template->param(ITEM_DATA => \@items);
$template->param(moredetailview => 1);
$template->param(loggedinuser => $loggedinuser);
$template->param(biblionumber => $biblionumber);
$template->param(biblioitemnumber => $bi);
$template->param(itemnumber => $itemnumber);
$template->param(additemnumber => $additemnumber);
$template->param(ONLY_ONE => 1) if ( $itemnumber && $count != @items );
$template->param(ShowSupressStatus => C4::Context->preference('ShowSupressStatus'));
$template->param(AllowHoldsOnDamagedItems => C4::Context->preference('AllowHoldsOnDamagedItems'));
output_html_with_http_headers $query, $cookie, $template->output;

sub _borrower
{
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("SELECT borrowernumber FROM borrowers
   WHERE userid = ?");
   $sth->execute(C4::Context->userenv->{id});
   return ($sth->fetchrow_array)[0];
}
