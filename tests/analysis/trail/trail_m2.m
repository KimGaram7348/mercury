%-----------------------------------------------------------------------------%

:- module trail_m2.
:- interface.

:- pred bbb(int::in) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module trail_m3.

%-----------------------------------------------------------------------------%

:- pragma no_inline(bbb/1).

bbb(N) :-
    ccc(N).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=8 sts=4 sw=4 et
