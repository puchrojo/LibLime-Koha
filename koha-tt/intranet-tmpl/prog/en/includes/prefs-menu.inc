<div id="menu">
<ul>
[% IF ( acquisitions ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Acquisitions" href="/cgi-bin/koha/admin/preferences.pl?tab=acquisitions">Acquisitions</a></li>
[% IF ( admin ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Administration" href="/cgi-bin/koha/admin/preferences.pl?tab=admin">Administration</a></li>
[% IF ( authorities ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Authority Control" href="/cgi-bin/koha/admin/preferences.pl?tab=authorities">Authorities</a></li>
[% IF ( cataloguing ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Cataloging" href="/cgi-bin/koha/admin/preferences.pl?tab=cataloguing">Cataloging</a></li>
[% IF ( circulation ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Circulation" href="/cgi-bin/koha/admin/preferences.pl?tab=circulation">Circulation</a></li>
[% IF ( creators ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Creators" href="/cgi-bin/koha/admin/preferences.pl?tab=creators">Creators</a></li>
[% IF ( enhanced_content ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Enhanced Content Settings" href="/cgi-bin/koha/admin/preferences.pl?tab=enhanced_content">Enhanced Content</a></li>
[% IF ( i18n_l10n ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Internationalization and Localization" href="/cgi-bin/koha/admin/preferences.pl?tab=i18n_l10n">I18N/L10N</a></li>
[% IF ( local_use ) %]<li class="active">[% ELSE %]<li>[% END %]<a href="/cgi-bin/koha/admin/systempreferences.pl">Local Use</a></li>
[% IF ( logs ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Transaction Logs" href="/cgi-bin/koha/admin/preferences.pl?tab=logs">Logs</a></li>
[% IF ( opac ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Online Public Access Catalog" href="/cgi-bin/koha/admin/preferences.pl?tab=opac">OPAC</a></li>
[% IF ( patrons ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Patrons" href="/cgi-bin/koha/admin/preferences.pl?tab=patrons">Patrons</a></li>
[% IF ( searching ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Searching" href="/cgi-bin/koha/admin/preferences.pl?tab=searching">Searching</a></li>
[% IF ( serials ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Serials" href="/cgi-bin/koha/admin/preferences.pl?tab=serials">Serials</a></li>
[% IF ( staff_client ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Staff Client" href="/cgi-bin/koha/admin/preferences.pl?tab=staff_client">Staff Client</a></li>
[% IF ( web_services ) %]<li class="active">[% ELSE %]<li>[% END %]<a title="Web Services" href="/cgi-bin/koha/admin/preferences.pl?tab=web_services">Web Services</a></li>
</ul>
</div>