%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2003-2004, 2006-2008 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: analysis.m.
% Main authors: stayl, wangp.
%
% An inter-module analysis framework, as described in
%
%   Nicholas Nethercote. The Analysis Framework of HAL,
%   Chapter 7: Inter-module Analysis, Master's Thesis,
%   University of Melbourne, September 2001, revised April 2002.
%   <http://www.cl.cam.ac.uk/~njn25/pubs/masters2001.ps.gz>.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module analysis.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module maybe.
:- import_module set.
:- import_module term.
:- import_module unit.

%-----------------------------------------------------------------------------%

    % The intention is that eventually any compiler can use this library
    % via .NET by defining an instance of this type class.
:- typeclass compiler(Compiler) where [
    func compiler_name(Compiler) = string,

    % Describe the analyses which can be performed by a compiler.
    %
    func analyses(Compiler, analysis_name) = analysis_type is semidet,

    % module_name_to_read_file_name(Compiler, ModuleName, Ext, FileName)
    %
    pred module_name_to_read_file_name(Compiler::in, module_name::in,
        string::in, maybe_error(string)::out, io::di, io::uo) is det,

    % module_name_to_write_file_name(Compiler, ModuleName, Ext, FileName)
    %
    pred module_name_to_write_file_name(Compiler::in, module_name::in,
        string::in, string::out, io::di, io::uo) is det
].

:- type analysis_name == string.

:- type analysis_type
    --->    some [FuncInfo, Call, Answer]
            analysis_type(
                unit(Call),
                unit(Answer)
            ) => analysis(FuncInfo, Call, Answer).

    % An analysis is defined by a type describing call patterns and
    % a type defining answer patterns.  If the analysis needs to store
    % more information about the function being analysed (e.g. arity)
    % it should be stored as part of the type for call patterns.
    %
:- typeclass analysis(FuncInfo, Call, Answer)
    <= (call_pattern(FuncInfo, Call),
        answer_pattern(FuncInfo, Answer))
    where
[
    func analysis_name(Call::unused, Answer::unused) =
        (analysis_name::out) is det,

    % The version number should be changed when the Call or Answer
    % types are changed so that results which use the old types
    % can be discarded.
    %
    func analysis_version_number(Call::unused, Answer::unused) =
        (int::out) is det,

    func preferred_fixpoint_type(Call::unused, Answer::unused) =
        (fixpoint_type::out) is det,

    func bottom(FuncInfo::in, Call::unused) = (Answer::out) is det,
    func top(FuncInfo::in, Call::unused) = (Answer::out) is det,

    pred get_func_info(module_info::in, module_name::in, func_id::in,
        Call::unused, Answer::unused, FuncInfo::out) is det
].

:- type fixpoint_type
    --->    least_fixpoint
            % Start at `bottom'.
            % Must run to completion.

    ;       greatest_fixpoint.
            % Start at `top'.
            % Can stop at any time.

:- typeclass call_pattern(FuncInfo, Call)
    <= (partial_order(FuncInfo, Call),
        to_term(Call))
    where [].

:- typeclass answer_pattern(FuncInfo, Answer)
    <= (partial_order(FuncInfo, Answer),
        to_term(Answer))
    where [].

:- type analysis_result(Call, Answer)
    --->    analysis_result(
                ar_call     :: Call,
                ar_answer   :: Answer,
                ar_status   :: analysis_status
            ).

:- typeclass partial_order(FuncInfo, T)
    <= (T -> FuncInfo)
    where
[
    pred more_precise_than(FuncInfo::in, T::in, T::in) is semidet,
    pred equivalent(FuncInfo::in, T::in, T::in) is semidet
].

:- typeclass to_term(S) where [
    func to_term(S) = term,
    pred from_term(term::in, S::out) is semidet
].

:- type no_func_info
    --->    no_func_info.

    % A call pattern that can be used by analyses that do not need
    % finer granularity.
    %
:- type any_call
    --->    any_call.

:- instance call_pattern(no_func_info, any_call).
:- instance partial_order(no_func_info, any_call).
:- instance to_term(any_call).

    % The status of a module or a specific analysis result.
    %
:- type analysis_status
    --->    invalid
    ;       suboptimal
    ;       optimal.

    % Least upper bound of two analysis_status values.
    %
:- func lub(analysis_status, analysis_status) = analysis_status.

    % This will need to encode language specific details like whether
    % it is a predicate or a function, and the arity and mode number.
:- type func_id
    --->    func_id(
                fid_pf      :: pred_or_func,
                fid_name    :: string,
                fid_arity   :: int,
                fid_mode    :: proc_id
            ).

:- type analysis_info.

:- func init_analysis_info(Compiler, module_name, bool) = analysis_info
    <= compiler(Compiler).

%-----------------------------------------------------------------------------%

    % Look up call patterns for all results for a given function.
    % Even if the module is `invalid' the call patterns will be returned.
    %
    % You should use this when you want to know which call patterns were
    % produced for a procedure defined in the current module in previous
    % passes.
    %
:- pred lookup_existing_call_patterns(analysis_info::in, analysis_name::in,
    module_name::in, func_id::in, list(Call)::out) is det
    <= call_pattern(FuncInfo, Call).

    % Look up all results for a given function.
    % If the module is `invalid' then the result list will be empty.
    %
    % N.B. Newly recorded results will NOT be found. This is intended
    % for looking up results from _other_ modules.
    %
:- pred lookup_results(analysis_info::in, module_name::in, func_id::in,
    list(analysis_result(Call, Answer))::out) is det
    <= analysis(FuncInfo, Call, Answer).

    % Look up all results for a given function and call pattern CP such
    % that the results have call patterns CP' that are equivalent to CP
    % or less specific than CP.
    %
    % N.B. Newly recorded results will NOT be found. This is intended
    % for looking up results from _other_ modules.
    %
:- pred lookup_matching_results(analysis_info::in, module_name::in,
    func_id::in, FuncInfo::in, Call::in,
    list(analysis_result(Call, Answer))::out) is det
    <= analysis(FuncInfo, Call, Answer).

    % Look up the best result matching a given call.
    %
    % N.B. Newly recorded results will NOT be found. This is intended
    % for looking up results from _other_ modules.
    %
    % If the returned best result has a call pattern that is different
    % from the given call pattern, then it is the analysis writer's
    % responsibility to request a more precise analysis from the called module,
    % using `record_request'.
    %
:- pred lookup_best_result(analysis_info::in, module_name::in, func_id::in,
    FuncInfo::in, Call::in, maybe(analysis_result(Call, Answer))::out) is det
    <= analysis(FuncInfo, Call, Answer).

    % Record an analysis result for a function.
    % Abort if the function is not from the module being analysed.
    % Does nothing if not making the analysis registry.
    %
:- pred record_result(module_name::in, func_id::in, Call::in, Answer::in,
    analysis_status::in, analysis_info::in, analysis_info::out) is det
    <= analysis(FuncInfo, Call, Answer).

    % Record the dependency of the module being analysed on the analysis
    % result of another module.
    % Does nothing if not making the analysis registry or if the result
    % that is depended upon comes from a non-local module.
    % Automatically makes a request if the call pattern hasn't been seen
    % before for that function.
    %
:- pred record_dependency(module_name::in, func_id::in, FuncInfo::in,
    Call::in, Answer::unused, analysis_info::in, analysis_info::out) is det
    <= analysis(FuncInfo, Call, Answer).

    % Lookup all the requests for a given function.
    % Abort if the function is not from the module being analysed.
    %
:- pred lookup_requests(analysis_info::in, analysis_name::in, module_name::in,
    func_id::in, list(Call)::out) is det
    <= call_pattern(FuncInfo, Call).

    % Record a request from the module being analysed on a function defined
    % in an imported module.
    % Does nothing if not making the analysis registry or if the function is
    % defined in a non-local module.
    %
:- pred record_request(analysis_name::in, module_name::in,
    func_id::in, Call::in, analysis_info::in, analysis_info::out) is det
    <= call_pattern(FuncInfo, Call).

%-----------------------------------------------------------------------------%

    % prepare_intermodule_analysis(ImportedModuleNames, LocalModuleNames,
    %   !Info, !IO)
    %
    % This predicate should be called before any pass begins to use the
    % analysis framework.  It ensures that all the analysis files 
    % are loaded so that lookups can be satisfied.  ImportedModuleNames is the
    % set of all modules that are directly or indirectly imported by the
    % module being analysed.  LocalModuleNames is the set of non-"library"
    % modules.
    %
:- pred prepare_intermodule_analysis(set(module_name)::in,
    set(module_name)::in, analysis_info::in, analysis_info::out,
    io::di, io::uo) is det.

     % module_is_local(Info, ModuleName, IsLocal).
     %
     % IsLocal is `yes' if the module is not a "library" module, i.e. we are
     % able to reanalyse the module. The set of local modules is set in
     % `prepare_intermodule_analysis'.
    %
:- pred module_is_local(analysis_info::in, module_name::in, bool::out)
    is det.

    % Should be called after all analysis is completed to write the
    % requests and results for the current compilation to the
    % analysis files.
    %
:- pred write_analysis_files(Compiler::in, module_info::in,
    set(module_name)::in, analysis_info::in, analysis_info::out,
    io::di, io::uo) is det
    <= compiler(Compiler).

%-----------------------------------------------------------------------------%

    % read_module_overall_status(Compiler, ModuleName, MaybeModuleStatus, !IO)
    %
    % Attempt to read the overall status from a module `.analysis' file.
    %
:- pred read_module_overall_status(Compiler::in, module_name::in,
    analysis_status::out, io::di, io::uo) is det
    <= compiler(Compiler).

:- pred enable_debug_messages(bool::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- include_module analysis.file.

:- import_module analysis.file.
:- import_module libs.
:- import_module libs.compiler_util.
:- import_module parse_tree.                % XXX unwanted dependency
:- import_module parse_tree.module_cmds.    % XXX unwanted dependency

:- import_module map.
:- import_module string.
:- import_module type_desc.
:- import_module univ.

%-----------------------------------------------------------------------------%

:- type analysis_info
    --->    some [Compiler]
            analysis_info(
                compiler :: Compiler,

                % The module being analysed.
                %
                this_module :: module_name,

                % Whether we are making the analysis registry or just using
                % results for .analysis files.
                %
                make_analysis_registry :: make_analysis_registry,

                % The set of local modules, i.e. for which we can issue
                % requests.
                %
                local_module_names :: set(module_name),

                % Holds outstanding requests for more specialised variants
                % of procedures. Requests are added to this map as analyses
                % proceed and written out to disk at the end of the
                % compilation of this module.
                %
                analysis_requests :: analysis_map(analysis_request),

                % The overall status of each module.
                %
                module_statuses :: map(module_name, analysis_status),

                % The "old" map stores analysis results read in from disk.
                % New results generated while analysing the current module
                % are added to the "new" map. After all the analyses
                % the two maps are compared to see which analysis results
                % have changed. Other modules may need to be marked or
                % invalidated as a result. Then "new" results are moved
                % into the "old" map, from where they can be written to disk.
                %
                old_analysis_results :: analysis_map(some_analysis_result),
                new_analysis_results :: module_analysis_map(
                                            some_analysis_result),

                % The Inter-module Dependency Graph records dependencies
                % of an entire module's analysis results on another module's
                % answer patterns. e.g. assume module M1 contains function F1
                % that has an analysis result that used the answer F2:CP2->AP2
                % from module M2. If AP2 changes then all of M1 will either be
                % marked `suboptimal' or `invalid'. Finer-grained dependency
                % tracking would allow only F1 to be recompiled, instead of
                % all of M1, but we don't do that.
                %
                % IMDGs are loaded from disk into the old map. During analysis
                % any dependences of the current module on other modules
                % is added into the new map. At the end of analysis all the
                % arcs which terminate at the current module are cleared
                % from the old map and replaced by those in the new map.
                %
                % XXX: Check if we really need two maps.
                %
                old_imdg :: analysis_map(imdg_arc),
                new_imdg :: analysis_map(imdg_arc)
            )
            => compiler(Compiler).

:- type make_analysis_registry
    --->    make_analysis_registry
    ;       use_analysis_registry_only.

    % An analysis result is a call pattern paired with an answer.
    % The result has a status associated with it.
    %
:- type some_analysis_result
    --->    some [FuncInfo, Call, Answer]
            some_analysis_result(
                some_ar_call    :: Call,
                some_ar_answer  :: Answer,
                some_ar_status  :: analysis_status
            )
            => analysis(FuncInfo, Call, Answer).

:- type analysis_request
    --->    some [FuncInfo, Call]
            analysis_request(
                req_call        :: Call,
                req_caller      :: module_name
            )
            => call_pattern(FuncInfo, Call).

:- type imdg_arc
    --->    some [FuncInfo, Call]
            imdg_arc(
                imdg_call       :: Call,
                                % Call pattern of the analysis result
                                % being depended on.
                imdg_caller     :: module_name
                                % The module that _depends on_ this
                                % function's result.
            )
            => call_pattern(FuncInfo, Call).

:- type analysis_map(T)         == map(module_name, module_analysis_map(T)).
:- type module_analysis_map(T)  == map(analysis_name, func_analysis_map(T)).
:- type func_analysis_map(T)    == map(func_id, list(T)).

%-----------------------------------------------------------------------------%
%
% The "any" call pattern
%

:- instance call_pattern(no_func_info, any_call) where [].
:- instance partial_order(no_func_info, any_call) where [
    ( more_precise_than(_, _, _) :-
        semidet_fail
    ),
    ( equivalent(no_func_info, _, _) :-
        semidet_succeed
    )
].
:- instance to_term(any_call) where [
    ( to_term(any_call) = Term :-
        Term = term.functor(atom("any"), [], context_init)
    ),
    ( from_term(Term, any_call) :-
        Term = term.functor(atom("any"), [], _)
    )
].

%-----------------------------------------------------------------------------%

init_analysis_info(Compiler, ThisModuleName, MakeAnalysisRegBool) = Info :-
    (
        MakeAnalysisRegBool = yes,
        MakeAnalysisReg = make_analysis_registry
    ;
        MakeAnalysisRegBool = no,
        MakeAnalysisReg = use_analysis_registry_only
    ),
    Info = 'new analysis_info'(Compiler, ThisModuleName, MakeAnalysisReg,
        set.init, map.init, map.init, map.init, map.init, map.init, map.init).

%-----------------------------------------------------------------------------%

lookup_existing_call_patterns(Info, AnalysisName, ModuleName, FuncId, Calls) :-
    ( ModuleName = Info ^ this_module ->
        true
    ;
        unexpected(this_file, "lookup_existing_call_patterns: not this_module")
    ),
    Map = Info ^ old_analysis_results,
    (
        ModuleResults = Map ^ elem(ModuleName),
        Results = ModuleResults ^ elem(AnalysisName) ^ elem(FuncId)
    ->
        Calls = list.map(
            (func(Result) = Call :-
                Result = some_analysis_result(Call0, _Answer, _Status),
                det_univ_to_type(univ(Call0), Call)
            ), Results)
    ;
        Calls = []
    ).

lookup_results(Info, ModuleName, FuncId, ResultList) :-
    AllowInvalidModules = no,
    lookup_results_1(Info, ModuleName, FuncId, AllowInvalidModules, ResultList).

:- pred lookup_results_1(analysis_info::in, module_name::in, func_id::in,
    bool::in, list(analysis_result(Call, Answer))::out) is det
    <= analysis(FuncInfo, Call, Answer).

lookup_results_1(Info, ModuleName, FuncId, AllowInvalidModules, ResultList) :-
    trace [io(!IO)] (
        debug_msg((pred(!.IO::di, !:IO::uo) is det :-
            io.write_string("% Looking up analysis results for ", !IO),
            io.write(ModuleName, !IO),
            io.write_string(".", !IO),
            io.write(FuncId, !IO),
            io.nl(!IO)
        ), !IO)
    ),
    (
        AllowInvalidModules = no,
        Info ^ module_statuses ^ elem(ModuleName) = invalid
    ->
        ResultList = []
    ;
        lookup_results_2(Info ^ old_analysis_results, ModuleName, FuncId,
            ResultList),
        trace [io(!IO)] (
            debug_msg((pred(!.IO::di, !:IO::uo) is det :-
                io.write_string("% Found these results: ", !IO),
                io.print(ResultList, !IO),
                io.nl(!IO)
            ), !IO)
        )
    ).

:- pred lookup_results_2(analysis_map(some_analysis_result)::in,
    module_name::in, func_id::in, list(analysis_result(Call, Answer))::out)
    is det <= analysis(FuncInfo, Call, Answer).

lookup_results_2(Map, ModuleName, FuncId, ResultList) :-
    AnalysisName = analysis_name(_ : Call, _ : Answer),
    (
        ModuleResults = Map ^ elem(ModuleName),
        Results = ModuleResults ^ elem(AnalysisName) ^ elem(FuncId)
    ->
        % XXX we might have to discard results which are
        % `invalid' or `fixpoint_invalid' if they are written at all
        ResultList = list.map(
            (func(Result) = analysis_result(Call, Answer, Status) :-
                Result = some_analysis_result(Call0, Answer0, Status),
                det_univ_to_type(univ(Call0), Call),
                det_univ_to_type(univ(Answer0), Answer)
            ), Results)
    ;
        ResultList = []
    ).

lookup_matching_results(Info, ModuleName, FuncId, FuncInfo, Call, ResultList) :-
    lookup_results(Info, ModuleName, FuncId, AllResultsList),
    ResultList = list.filter(
        (pred(Result::in) is semidet :-
            ResultCall = Result ^ ar_call,
            ( more_precise_than(FuncInfo, Call, ResultCall)
            ; equivalent(FuncInfo, Call, ResultCall)
            )
        ), AllResultsList).

lookup_best_result(Info, ModuleName, FuncId, FuncInfo, Call, MaybeBestResult) :-
    trace [io(!IO)] (
        debug_msg((pred(!.IO::di, !:IO::uo) is det :-
            io.write_string("% Looking up best analysis result for ", !IO),
            io.write(ModuleName, !IO),
            io.write_string(".", !IO),
            io.write(FuncId, !IO),
            io.nl(!IO)
        ), !IO)
    ),
    lookup_matching_results(Info, ModuleName, FuncId, FuncInfo, Call,
        MatchingResults),
    (
        MatchingResults = [],
        MaybeBestResult = no
    ;
        MatchingResults = [Result | Results],
        list.foldl(more_precise_answer(FuncInfo), Results, Result, BestResult),
        MaybeBestResult = yes(BestResult)
    ).

:- pred more_precise_answer(FuncInfo::in,
    analysis_result(Call, Answer)::in, analysis_result(Call, Answer)::in,
    analysis_result(Call, Answer)::out) is det
    <= analysis(FuncInfo, Call, Answer).

more_precise_answer(FuncInfo, Result, Best0, Best) :-
    ResultAnswer = Result ^ ar_answer,
    BestAnswer0 = Best0 ^ ar_answer,
    ( more_precise_than(FuncInfo, ResultAnswer, BestAnswer0) ->
        Best = Result
    ; 
        Best = Best0
    ).

:- pred lookup_exactly_matching_result_even_from_invalid_modules(
    analysis_info::in, module_name::in, func_id::in, FuncInfo::in, Call::in,
    maybe(analysis_result(Call, Answer))::out) is det
    <= analysis(FuncInfo, Call, Answer).

lookup_exactly_matching_result_even_from_invalid_modules(Info, ModuleName,
        FuncId, FuncInfo, Call, MaybeResult) :-
    AllowInvalidModules = yes,
    lookup_results_1(Info, ModuleName, FuncId, AllowInvalidModules,
        AllResultsList),
    ResultList = list.filter(
        (pred(R::in) is semidet :-
            equivalent(FuncInfo, Call, R ^ ar_call)
        ), AllResultsList),
    (
        ResultList = [],
        MaybeResult = no
    ;
        ResultList = [Result],
        MaybeResult = yes(Result)
    ;
        ResultList = [_, _ | _],
        unexpected(this_file,
            "lookup_exactly_matching_result: " ++
            "zero or one exactly matching results expected")
    ).

%-----------------------------------------------------------------------------%

record_result(ModuleName, FuncId, CallPattern, AnswerPattern, Status, !Info) :-
    ( ModuleName = !.Info ^ this_module ->
        true
    ;
        unexpected(this_file,
            "record_result: recording result for procedure " ++
            "defined in another module")
    ),

    MakeAnalysisReg = !.Info ^ make_analysis_registry,
    (
        MakeAnalysisReg = make_analysis_registry,
        Map0 = !.Info ^ new_analysis_results,
        record_result_in_analysis_map(FuncId, CallPattern, AnswerPattern,
            Status, Map0, Map),
        !Info ^ new_analysis_results := Map
    ;
        MakeAnalysisReg = use_analysis_registry_only
    ).

:- pred record_result_in_analysis_map(func_id::in,
    Call::in, Answer::in, analysis_status::in,
    module_analysis_map(some_analysis_result)::in,
    module_analysis_map(some_analysis_result)::out) is det
    <= analysis(FuncInfo, Call, Answer).

record_result_in_analysis_map(FuncId, CallPattern, AnswerPattern, Status,
        ModuleResults0, ModuleResults) :-
    AnalysisName = analysis_name(CallPattern, AnswerPattern),
    ( map.search(ModuleResults0, AnalysisName, AnalysisResults0) ->
        AnalysisResults1 = AnalysisResults0
    ;
        AnalysisResults1 = map.init
    ),
    ( map.search(AnalysisResults1, FuncId, FuncResults0) ->
        FuncResults1 = FuncResults0
    ;
        FuncResults1 = []
    ),
    Result = 'new some_analysis_result'(CallPattern, AnswerPattern, Status),
    FuncResults = [Result | FuncResults1],
    ModuleResults =
        map.set(ModuleResults0, AnalysisName,
            map.set(AnalysisResults1, FuncId, FuncResults)).

%-----------------------------------------------------------------------------%

lookup_requests(Info, AnalysisName, ModuleName, FuncId, CallPatterns) :-
    ( ModuleName = Info ^ this_module ->
        true
    ;
        unexpected(this_file, "lookup_requests: not this_module")
    ),
    (
        map.search(Info ^ analysis_requests, ModuleName, ModuleRequests),
        CallPatterns0 = ModuleRequests ^ elem(AnalysisName) ^ elem(FuncId)
    ->
        CallPatterns1 = list.filter_map(
            (func(analysis_request(Call0, _)) = Call is semidet :-
                univ(Call) = univ(Call0)
            ), CallPatterns0),
        % Requests simply get appended to `.request' files so when we read them
        % back in there may be duplicates.
        list.sort_and_remove_dups(CallPatterns1, CallPatterns)
    ;
        CallPatterns = []
    ).

record_request(AnalysisName, ModuleName, FuncId, CallPattern, !Info) :-
    ThisModule = !.Info ^ this_module,
    ( ThisModule = ModuleName ->
        unexpected(this_file, "record_request: request on self")
    ;
        true
    ),

    MakeAnalysisReg = !.Info ^ make_analysis_registry,
    module_is_local(!.Info, ModuleName, IsLocal),
    (
        MakeAnalysisReg = make_analysis_registry,
        IsLocal = yes
    ->
        record_request_2(ThisModule, AnalysisName, ModuleName, FuncId,
            CallPattern, !Info)
    ;
        true
    ).

:- pred record_request_2(module_name::in, analysis_name::in, module_name::in,
    func_id::in, Call::in, analysis_info::in, analysis_info::out) is det
    <= call_pattern(FuncInfo, Call).

record_request_2(CallerModule, AnalysisName, ModuleName, FuncId, CallPattern,
        !Info) :-
    ( ModuleResults0 = map.search(!.Info ^ analysis_requests, ModuleName) ->
        ModuleResults1 = ModuleResults0
    ;
        ModuleResults1 = map.init
    ),
    ( AnalysisResults0 = map.search(ModuleResults1, AnalysisName) ->
        AnalysisResults1 = AnalysisResults0
    ;
        AnalysisResults1 = map.init
    ),
    ( FuncResults0 = map.search(AnalysisResults1, FuncId) ->
        FuncResults1 = FuncResults0
    ;
        FuncResults1 = []
    ),
    Request = 'new analysis_request'(CallPattern, CallerModule),
    FuncResults = [Request | FuncResults1],
    !Info ^ analysis_requests :=
        map.set(!.Info ^ analysis_requests, ModuleName,
            map.set(ModuleResults1, AnalysisName,
                map.set(AnalysisResults1, FuncId, FuncResults))).

%-----------------------------------------------------------------------------%

record_dependency(CalleeModuleName, FuncId, FuncInfo, Call, DummyAnswer,
        !Info) :-
    ThisModule = !.Info ^ this_module,
    ( ThisModule = CalleeModuleName ->
        unexpected(this_file, "record_dependency: dependency on self")
    ;
        true
    ),

    MakeAnalysisReg = !.Info ^ make_analysis_registry,
    module_is_local(!.Info, CalleeModuleName, IsLocal),
    (
        MakeAnalysisReg = make_analysis_registry,
        IsLocal = yes
    ->
        AnalysisName = analysis_name(Call, DummyAnswer),
        record_dependency_2(ThisModule, AnalysisName, CalleeModuleName, FuncId,
            Call, !Info),

        % If the call pattern that's being depended on hasn't been analysed
        % before, make a request for it.
        lookup_exactly_matching_result_even_from_invalid_modules(!.Info,
            CalleeModuleName, FuncId, FuncInfo, Call, MaybeResult),
        (
            MaybeResult = no,
            record_request(AnalysisName, CalleeModuleName, FuncId, Call, !Info)
        ;
            MaybeResult = yes(Result),
            same_type(Result, analysis_result(Call, DummyAnswer, _))
        )
    ;
        true
    ).

:- pred record_dependency_2(module_name::in, analysis_name::in,
    module_name::in, func_id::in, Call::in,
    analysis_info::in, analysis_info::out) is det
    <= call_pattern(FuncInfo, Call).

record_dependency_2(CallerModuleName, AnalysisName, CalleeModuleName, FuncId,
        Call, !Info) :-
    ( Analyses0 = map.search(!.Info ^ new_imdg, CalleeModuleName) ->
        Analyses1 = Analyses0
    ;
        Analyses1 = map.init
    ),
    ( Funcs0 = map.search(Analyses1, AnalysisName) ->
        Funcs1 = Funcs0
    ;
        Funcs1 = map.init
    ),
    ( FuncArcs0 = map.search(Funcs1, FuncId) ->
        FuncArcs1 = FuncArcs0
    ;
        FuncArcs1 = []
    ),
    Dep = 'new imdg_arc'(Call, CallerModuleName),
    % XXX this should really be a set to begin with
    ( list.member(Dep, FuncArcs1) ->
        true
    ;
        FuncArcs = [Dep | FuncArcs1],
        !Info ^ new_imdg :=
            map.set(!.Info ^ new_imdg, CalleeModuleName,
                map.set(Analyses1, AnalysisName,
                    map.set(Funcs1, FuncId, FuncArcs)))
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % The algorithm is from Nick's thesis, pp. 108-9.
    % Or my corruption thereof.
    % See the `analysis/README' file for a reference.
    %
    % For each new analysis result (P^M:DP --> Ans_new):
    %   Read in the registry of M if necessary
    %   If there is an existing analysis result (P^M:DP --> Ans_old):
    %   if Ans_new \= Ans_old:
    %       Replace the entry in the registry with P^M:DP --> Ans_new
    %       if Ans_new `more_precise_than` Ans_old
    %       Status = suboptimal
    %       else
    %       Status = invalid
    %       For each entry (Q^N:DQ --> P^M:DP) in the IMDG:
    %       % Mark Q^N:DQ --> _ (_) with Status
    %       Actually, we don't do that.  We only mark the
    %       module N's _overall_ status with the
    %       least upper bound of its old status and Status.
    %   Else (P:DP --> Ans_old) did not exist:
    %   Insert result (P:DP --> Ans_new) into the registry.
    %
    % Finally, clear out the "new" analysis results map.  When we write
    % out the analysis files we will do it from the "old" results map.
    %
    % In a similar way, any new results which satisfy a request cause the
    % module that made the request to be marked suboptimal. 
    %
:- pred update_analysis_registry(module_info::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

update_analysis_registry(ModuleInfo, !Info, !IO) :-
    debug_msg(io.write_string("% Updating analysis registry.\n"), !IO),
    NewResults = !.Info ^ new_analysis_results,
    update_analysis_registry_2(ModuleInfo, !.Info ^ this_module, NewResults,
        !Info, !IO),
    !Info ^ new_analysis_results := map.init.

:- pred update_analysis_registry_2(module_info::in, module_name::in,
    module_analysis_map(some_analysis_result)::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

update_analysis_registry_2(ModuleInfo, ModuleName, ModuleMap, !Info, !IO) :-
    map.foldl2(update_analysis_registry_3(ModuleInfo, ModuleName), ModuleMap,
        !Info, !IO).

:- pred update_analysis_registry_3(module_info::in, module_name::in,
    analysis_name::in, func_analysis_map(some_analysis_result)::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

update_analysis_registry_3(ModuleInfo, ModuleName, AnalysisName, FuncMap,
        !Info, !IO) :-
    map.foldl2(update_analysis_registry_4(ModuleInfo, ModuleName, AnalysisName),
        FuncMap, !Info, !IO).

:- pred update_analysis_registry_4(module_info::in, module_name::in,
    analysis_name::in, func_id::in, list(some_analysis_result)::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

update_analysis_registry_4(ModuleInfo, ModuleName, AnalysisName, FuncId,
        NewResults, !Info, !IO) :-
    % XXX Currently we do not prevent there being more than one recorded result
    % for a given call pattern.
    list.foldl2(update_analysis_registry_5(ModuleInfo, ModuleName, AnalysisName,
        FuncId), NewResults, !Info, !IO).

:- pred update_analysis_registry_5(module_info::in, module_name::in,
    analysis_name::in, func_id::in, some_analysis_result::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

update_analysis_registry_5(ModuleInfo, ModuleName, AnalysisName, FuncId,
        NewResult, !Info, !IO) :-
    NewResult = some_analysis_result(Call, NewAnswer, NewStatus),
    get_func_info(ModuleInfo, ModuleName, FuncId, Call, NewAnswer, FuncInfo),
    lookup_exactly_matching_result_even_from_invalid_modules(!.Info,
        ModuleName, FuncId, FuncInfo, Call, MaybeResult),
    (
        % There was a previous answer for this call pattern.
        %
        MaybeResult = yes(OldResult),
        OldResult = analysis_result(_OldCall, OldAnswer, OldStatus),
        ( equivalent(FuncInfo, NewAnswer, OldAnswer) ->
            debug_msg(write_no_change_in_result(ModuleName, FuncId, Call,
                NewAnswer), !IO),
            ( NewStatus \= OldStatus ->
                OldMap0 = !.Info ^ old_analysis_results,
                replace_result_in_analysis_map(ModuleName, FuncId, FuncInfo,
                    Call, NewAnswer, NewStatus, OldMap0, OldMap),
                !Info ^ old_analysis_results := OldMap
            ;
                true
            )
        ;
            % Answer has changed.
            % Replace the old answer in the registry with the new answer.
            OldMap0 = !.Info ^ old_analysis_results,
            replace_result_in_analysis_map(ModuleName, FuncId, FuncInfo,
                Call, NewAnswer, NewStatus, OldMap0, OldMap),
            !Info ^ old_analysis_results := OldMap,

            % If the answer is more precise than before then dependent modules
            % should be marked suboptimal. Otherwise the answer is less precise
            % than it was before, so dependent modules should be invalidated.
            ( more_precise_than(FuncInfo, NewAnswer, OldAnswer) ->
                Status = suboptimal
            ;
                Status = invalid
            ),
            OldArcs = !.Info ^ old_imdg ^ det_elem(ModuleName),
            DepModules = imdg_dependent_modules(OldArcs, AnalysisName,
                FuncId, FuncInfo, Call),
            debug_msg(write_changed_answer(OldAnswer, NewAnswer, Status,
                DepModules), !IO),
            set.fold2(taint_module_overall_status(Status), DepModules,
                !Info, !IO)
        )
    ;
        % There was no previous answer for this call pattern.
        % Just add this result to the registry.
        MaybeResult = no,
        OldMap0 = !.Info ^ old_analysis_results ^ det_elem(ModuleName),
        record_result_in_analysis_map(FuncId, Call, NewAnswer, NewStatus,
            OldMap0, OldMap),
        !Info ^ old_analysis_results ^ elem(ModuleName) := OldMap
    ),

    % If this new result satisfies a request then mark the requesting modules
    % as suboptimal so they can be reanalysed.
    %
    % Ideally we could compare the new answer with either a default answer that
    % the calling module probably used, or each request could optionally record
    % what answer the caller assumed.  Then we could avoid reanalysing the
    % calling module unnecessarily.  (This only reason we don't implement
    % the former is that the structure reuse analysis doesn't implement
    % the `top' typeclass method.)
    (
        map.search(!.Info ^ analysis_requests, ModuleName, ModuleRequests),
        Requests = ModuleRequests ^ elem(AnalysisName) ^ elem(FuncId),
        Requests = [_ | _]
    ->
        Callers0 = list.filter_map(
            (func(analysis_request(Call0, Caller)) = Caller is semidet :-
                univ(Call0) = univ(Call0)
            ), Requests),
        list.sort_and_remove_dups(Callers0, Callers),
        list.foldl2(taint_module_overall_status(suboptimal), Callers,
            !Info, !IO)
    ;
        true
    ).

    % Replace an analysis result for the given function/call pattern with a
    % new result. A previous result _must_ already exist in the map with
    % exactly the same call pattern.
    %
:- pred replace_result_in_analysis_map(module_name::in, func_id::in,
    FuncInfo::in, Call::in, Answer::in, analysis_status::in,
    analysis_map(some_analysis_result)::in,
    analysis_map(some_analysis_result)::out) is det
    <= analysis(FuncInfo, Call, Answer).

replace_result_in_analysis_map(ModuleName, FuncId, FuncInfo,
        CallPattern, AnswerPattern, Status, Map0, Map) :-
    AnalysisName = analysis_name(CallPattern, AnswerPattern),
    ModuleResults0 = map.lookup(Map0, ModuleName),
    AnalysisResults0 = map.lookup(ModuleResults0, AnalysisName),
    FuncResults0 = map.lookup(AnalysisResults0, FuncId),
    replace_result_in_list(FuncInfo, CallPattern, AnswerPattern, Status,
    FuncResults0, FuncResults),
    Map = map.det_update(Map0, ModuleName,
    map.det_update(ModuleResults0, AnalysisName,
    map.det_update(AnalysisResults0, FuncId, FuncResults))).

:- pred replace_result_in_list(FuncInfo::in, Call::in, Answer::in,
    analysis_status::in,
    list(some_analysis_result)::in, list(some_analysis_result)::out) is det
    <= analysis(FuncInfo, Call, Answer).

replace_result_in_list(FuncInfo, Call, Answer, Status, Results0, Results) :-
    (
        Results0 = [],
        unexpected(this_file,
            "replace_result_in_list: found no result to replace")
    ;
        Results0 = [H0 | T0],
        det_univ_to_type(univ(H0 ^ some_ar_call), HCall),
        ( equivalent(FuncInfo, Call, HCall) ->
            H = 'new some_analysis_result'(Call, Answer, Status),
            T = T0
        ;
            H = H0,
            replace_result_in_list(FuncInfo, Call, Answer, Status, T0, T)
        ),
        Results = [H | T]
    ).

:- func imdg_dependent_modules(module_analysis_map(imdg_arc), analysis_name,
    func_id, FuncInfo, Call) = set(module_name)
    <= call_pattern(FuncInfo, Call).

imdg_dependent_modules(ModuleMap, AnalysisName, FuncId, FuncInfo, Call) =
    (
        map.search(ModuleMap, AnalysisName, FuncAnalysisMap),
        map.search(FuncAnalysisMap, FuncId, IMDGEntries)
    ->
        set.from_list(list.filter_map(arc_module_name(FuncInfo, Call),
            IMDGEntries))
    ;
        set.init
    ).

    % XXX: compiler aborts if the modes are removed
:- func arc_module_name(FuncInfo::in, Call::in, imdg_arc::in) =
    (module_name::out) is semidet
    <= call_pattern(FuncInfo, Call).

arc_module_name(FuncInfo, CallA, imdg_arc(CallB0, ModuleName)) = ModuleName :-
    det_univ_to_type(univ(CallB0), CallB),
    equivalent(FuncInfo, CallA, CallB).

:- pred taint_module_overall_status(analysis_status::in, module_name::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

taint_module_overall_status(Status, ModuleName, !Info, !IO) :-
    (
        Status = optimal
    ;
        ( Status = suboptimal
        ; Status = invalid
        ),

        % We may not have read the overall status for this module yet.
        % Even though we loaded all the analysis files of modules reachable
        % from the initial module beforehand, a _caller_ of the initial module
        % may not be part of that set.
        ensure_module_status_loaded(ModuleName, !Info, !IO),

        ModuleStatus0 = !.Info ^ module_statuses ^ det_elem(ModuleName),
        ModuleStatus = lub(ModuleStatus0, Status),
        debug_msg(write_tainting_module(ModuleName, ModuleStatus), !IO),
        !Info ^ module_statuses ^ elem(ModuleName) := ModuleStatus
    ).

:- pred ensure_module_status_loaded(module_name::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

ensure_module_status_loaded(ModuleName, !Info, !IO) :-
    ( map.contains(!.Info ^ module_statuses, ModuleName) ->
        true
    ;
        analysis.read_module_overall_status(!.Info ^ compiler, ModuleName,
            ModuleStatus, !IO),
        !Info ^ module_statuses ^ elem(ModuleName) := ModuleStatus
    ).

:- pred write_no_change_in_result(module_name::in, func_id::in, Call::in,
    Answer::in, io::di, io::uo) is det.

write_no_change_in_result(ModuleName, FuncId, Call, NewAnswer, !IO) :-
    io.write_string("% No change in the result ", !IO),
    io.write(ModuleName, !IO),
    io.write_string(".", !IO),
    io.write(FuncId, !IO),
    io.write_string(":", !IO),
    io.write(Call, !IO),
    io.write_string(" --> ", !IO),
    io.write(NewAnswer, !IO),
    io.nl(!IO).

:- pred write_changed_answer(Answer::in, Answer::in, analysis_status::in,
    set(module_name)::in, io::di, io::uo) is det.

write_changed_answer(OldAnswer, NewAnswer, Status, DepModules, !IO) :-
    io.write_string("% ", !IO),
    io.write(OldAnswer, !IO),
    io.write_string(" changed to ", !IO),
    io.write(NewAnswer, !IO),
    io.nl(!IO),
    io.write_string("Mark dependent modules as ", !IO),
    io.write(Status, !IO),
    io.nl(!IO),
    io.write_string("The modules to mark are: ", !IO),
    io.write(DepModules, !IO),
    io.nl(!IO).

:- pred write_tainting_module(module_name::in, analysis_status::in,
    io::di, io::uo) is det.

write_tainting_module(ModuleName, ModuleStatus, !IO) :-
    io.print("% Tainting the overall module status of ", !IO),
    io.print(ModuleName, !IO),
    io.print(" with ", !IO),
    io.print(ModuleStatus, !IO),
    io.nl(!IO).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % For each module N imported by M:
    %   Delete all entries leading to module M from N's IMDG:
    %   For each P^M:DP in S (call patterns to analyse):
    %       add P^M:DP --> Q^N:DQ to N's IMDG
    %
:- pred update_intermodule_dependencies(module_name::in, set(module_name)::in,
    analysis_info::in, analysis_info::out) is det.

update_intermodule_dependencies(ModuleName, LocalImportedModules, !Info) :-
    set.fold(update_intermodule_dependencies_2(ModuleName),
        LocalImportedModules, !Info).

:- pred update_intermodule_dependencies_2(module_name::in, module_name::in,
    analysis_info::in, analysis_info::out) is det.

update_intermodule_dependencies_2(ModuleName, ImportedModuleName, !Info) :-
    map.lookup(!.Info ^ old_imdg, ImportedModuleName, IMDG0),
    trace [io(!IO)] (
        debug_msg(write_clearing_entries(ModuleName, ImportedModuleName),
            !IO)
    ),
    clear_imdg_entries_pointing_at(ModuleName, IMDG0, IMDG1),

    ( NewArcs = !.Info ^ new_imdg ^ elem(ImportedModuleName) ->
        map.union(combine_func_imdg, IMDG1, NewArcs, IMDG)
    ;
        IMDG = IMDG1
    ),
    !Info ^ old_imdg ^ elem(ImportedModuleName) := IMDG,
    !Info ^ new_imdg := map.delete(!.Info ^ new_imdg, ImportedModuleName).

:- pred write_clearing_entries(module_name::in, module_name::in,
    io::di, io::uo) is det.

write_clearing_entries(ModuleName, ImportedModuleName, !IO) :-
    io.write_string("% Clearing entries involving ", !IO),
    io.write(ModuleName, !IO),
    io.write_string(" from ", !IO),
    io.write(ImportedModuleName, !IO),
    io.write_string("'s IMDG.\n", !IO).

:- pred clear_imdg_entries_pointing_at(module_name::in,
    module_analysis_map(imdg_arc)::in,
    module_analysis_map(imdg_arc)::out) is det.

clear_imdg_entries_pointing_at(ModuleName, Map0, Map) :-
    map.map_values(clear_imdg_entries_pointing_at_2(ModuleName), Map0, Map).

:- pred clear_imdg_entries_pointing_at_2(module_name::in, analysis_name::in,
    func_analysis_map(imdg_arc)::in,
    func_analysis_map(imdg_arc)::out) is det.

clear_imdg_entries_pointing_at_2(ModuleName, _, FuncMap0, FuncMap) :-
    map.map_values(clear_imdg_entries_pointing_at_3(ModuleName),
        FuncMap0, FuncMap).

:- pred clear_imdg_entries_pointing_at_3(module_name::in, func_id::in,
    list(imdg_arc)::in, list(imdg_arc)::out) is det.

clear_imdg_entries_pointing_at_3(ModuleName, _, Arcs0, Arcs) :-
    list.filter((pred(Arc::in) is semidet :- Arc ^ imdg_caller \= ModuleName),
        Arcs0, Arcs).

:- pred combine_func_imdg(func_analysis_map(imdg_arc)::in,
    func_analysis_map(imdg_arc)::in, func_analysis_map(imdg_arc)::out) is det.

combine_func_imdg(FuncImdgA, FuncImdgB, FuncImdg) :-
    map.union(combine_imdg_lists, FuncImdgA, FuncImdgB, FuncImdg).

:- pred combine_imdg_lists(list(imdg_arc)::in, list(imdg_arc)::in,
    list(imdg_arc)::out) is det.

combine_imdg_lists(ArcsA, ArcsB, ArcsA ++ ArcsB).

%-----------------------------------------------------------------------------%

prepare_intermodule_analysis(ImportedModuleNames0, LocalModuleNames, !Info,
        !IO) :-
    ThisModule = !.Info ^ this_module,
    ImportedModuleNames = set.delete(ImportedModuleNames0, ThisModule),

    !Info ^ local_module_names := LocalModuleNames,

    % Read in results for imported modules.
    set.fold2(load_module_analysis_results, ImportedModuleNames, !Info, !IO),

    % Read in results and requests for the module being analysed.
    load_module_analysis_results(ThisModule, !Info, !IO),
    read_module_analysis_requests(!.Info, ThisModule, ThisModuleRequests, !IO),
    !Info ^ analysis_requests ^ elem(ThisModule) := ThisModuleRequests.

:- pred load_module_analysis_results(module_name::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

load_module_analysis_results(ModuleName, !Info, !IO) :-
    (
        ( map.contains(!.Info ^ old_analysis_results, ModuleName)
        ; map.contains(!.Info ^ module_statuses, ModuleName)
        )
    ->
        unexpected(this_file, "ensure_old_module_analysis_results_loaded")
    ;
        analysis.read_module_overall_status(!.Info ^ compiler, ModuleName,
            ModuleStatus, !IO),
        read_module_analysis_results(!.Info, ModuleName, ModuleResults, !IO),
        !Info ^ module_statuses ^ elem(ModuleName) := ModuleStatus,
        !Info ^ old_analysis_results ^ elem(ModuleName) := ModuleResults
    ).

module_is_local(Info, ModuleName, IsLocal) :-
    ( set.contains(Info ^ local_module_names, ModuleName) ->
        IsLocal = yes
    ;
        IsLocal = no
    ).

%-----------------------------------------------------------------------------%

    % In this procedure we have just finished compiling module ModuleName
    % and will write out data currently cached in the analysis_info structure
    % out to disk.
    %
write_analysis_files(Compiler, ModuleInfo, ImportedModule0, !Info, !IO) :-
    ThisModule = !.Info ^ this_module,
    ImportedModules = set.delete(ImportedModule0, ThisModule),

    LocalModules = !.Info ^ local_module_names,
    LocalImportedModules = set.intersect(LocalModules, ImportedModules),

    % Load IMDG files for local modules.
    set.fold2(load_module_imdg, LocalModules, !Info, !IO),

    update_analysis_registry(ModuleInfo, !Info, !IO),

    % The current module was just compiled so we set its status to the
    % lub of all the new analysis results generated.
    ModuleStatus = lub_result_statuses(!.Info ^ new_analysis_results),
    !Info ^ module_statuses ^ elem(ThisModule) := ModuleStatus,

    update_intermodule_dependencies(ThisModule, LocalImportedModules, !Info),
    ( map.is_empty(!.Info ^ new_analysis_results) ->
        true
    ;
        unexpected(this_file,
            "write_analysis_files: new_analysis_results is not empty")
    ),

    % Write the module statuses for all local modules (not necessarily
    % imported).
    set.fold(maybe_write_module_overall_status(!.Info), LocalModules, !IO),

    % Write the analysis results for the current module.
    ModuleResults = !.Info ^ old_analysis_results ^ det_elem(ThisModule),
    write_module_analysis_results(!.Info, ThisModule, ModuleResults, !IO),

    % Write the requests for imported local modules.
    set.fold(maybe_write_module_requests(!.Info), LocalImportedModules, !IO),

    % Remove the requests for the current module since we (should have)
    % fulfilled them in this pass.
    empty_request_file(!.Info, ThisModule, !IO),

    % Write the intermodule dependency graphs.
    set.fold(maybe_write_module_imdg(!.Info), LocalImportedModules, !IO),

    % Touch a timestamp file to indicate the last time that this module was
    % analysed.
    module_name_to_write_file_name(Compiler, ThisModule, ".analysis_date",
        TimestampFileName, !IO),
    touch_datestamp(TimestampFileName, !IO).

:- pred load_module_imdg(module_name::in,
    analysis_info::in, analysis_info::out, io::di, io::uo) is det.

load_module_imdg(ModuleName, !Info, !IO) :-
    read_module_imdg(!.Info, ModuleName, IMDG, !IO),
    Map0 = !.Info ^ old_imdg,
    map.det_insert(Map0, ModuleName, IMDG, Map),
    !Info ^ old_imdg := Map.

:- pred maybe_write_module_overall_status(analysis_info::in, module_name::in,
    io::di, io::uo) is det.

maybe_write_module_overall_status(Info, ModuleName, !IO) :-
    ( map.search(Info ^ module_statuses, ModuleName, Status) ->
        analysis.file.write_module_overall_status(Info, ModuleName, Status,
            !IO)
    ;
        % We didn't have any reason to read in the status of this module
        % so we have no reason to touch it either.
        true
    ).

:- pred maybe_write_module_requests(analysis_info::in, module_name::in,
    io::di, io::uo) is det.

maybe_write_module_requests(Info, ModuleName, !IO) :-
    ( map.search(Info ^ analysis_requests, ModuleName, Requests) ->
        analysis.file.write_module_analysis_requests(Info, ModuleName,
            Requests, !IO)
    ;
        true
    ).

:- pred maybe_write_module_imdg(analysis_info::in, module_name::in,
    io::di, io::uo) is det.

maybe_write_module_imdg(Info, ModuleName, !IO) :-
    ( map.search(Info ^ old_imdg, ModuleName, ModuleEntries) ->
        analysis.file.write_module_imdg(Info, ModuleName, ModuleEntries, !IO)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

read_module_overall_status(Compiler, ModuleName, ModuleStatus, !IO) :-
    analysis.file.read_module_overall_status(Compiler, ModuleName,
        ModuleStatus, !IO).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

lub(StatusA, StatusB) = Status :-
    compare(Cmp, StatusA, StatusB),
    (
        Cmp = (=),
        Status = StatusA
    ;
        Cmp = (<),
        Status = StatusA
    ;
        Cmp = (>),
        Status = StatusB
    ).

:- func lub_result_statuses(module_analysis_map(some_analysis_result))
    = analysis_status.

lub_result_statuses(ModuleMap) =
    map.foldl(lub_result_statuses_2, ModuleMap, optimal).

:- func lub_result_statuses_2(analysis_name,
    func_analysis_map(some_analysis_result), analysis_status) =
    analysis_status.

lub_result_statuses_2(_AnalysisName, FuncMap, Acc) =
    map.foldl(lub_result_statuses_3, FuncMap, Acc).

:- func lub_result_statuses_3(func_id, list(some_analysis_result),
    analysis_status) = analysis_status.

lub_result_statuses_3(_FuncId, Results, Acc) =
    list.foldl(lub_result_statuses_4, Results, Acc).

:- func lub_result_statuses_4(some_analysis_result, analysis_status)
    = analysis_status.

lub_result_statuses_4(Result, Acc) = lub(Result ^ some_ar_status, Acc).

%-----------------------------------------------------------------------------%

:- mutable(debug_analysis, bool, no, ground, [untrailed, attach_to_io_state]).

enable_debug_messages(Debug, !IO) :-
    set_debug_analysis(Debug, !IO).

:- pred debug_msg(pred(io, io)::in(pred(di, uo) is det), io::di, io::uo)
    is det.

debug_msg(P, !IO) :-
    get_debug_analysis(Debug, !IO),
    (
        Debug = yes,
        P(!IO)
    ;
        Debug = no
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "analysis.m".

%-----------------------------------------------------------------------------%
:- end_module analysis.
%-----------------------------------------------------------------------------%