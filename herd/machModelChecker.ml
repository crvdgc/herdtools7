(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2013-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(** Check an event structure against a machine model *)

module type Config = sig
  val m : AST.t
  val bell_model_info : (string * BellModel.info) option
  include Model.Config
end

module Make
    (O:Config)
    (S:Sem.Semantics)
    =
  struct

    let bell_fname =  Misc.app_opt (fun (x,_) -> x) O.bell_model_info
    let bell_info = Misc.app_opt (fun (_,x) -> x) O.bell_model_info

    module IConfig = struct
      let bell = false
      let bell_fname = bell_fname
      include O
      let doshow = S.O.PC.doshow
      let showraw = S.O.PC.showraw
      let symetric = S.O.PC.symetric
    end
    module U = MemUtils.Make(S)
    module MU = ModelUtils.Make(O)(S)

    module IUtils = struct
      let partition_events = U.partition_events
      let loc2events x es =
        let open S in
        let x = A.V.nameToV x in
        E.EventSet.filter
          (fun e -> match E.location_of e with
          | Some (A.Location_global loc) -> A.V.compare loc x = 0
          | None | Some _ -> false)
          es
              
      let check_through = MU.check_through
      let pp_failure test conc msg vb_pp =
        MU.pp_failure
          test conc
          (Printf.sprintf "%s: %s" test.Test.name.Name.name msg)
          vb_pp
    end
    module I = Interpreter.Make(IConfig)(S)(IUtils)
    module E = S.E

(* Local utility: bell event selection *)
    let add_bell_events m pred evts annots =
      I.add_sets m
        (StringSet.fold
           (fun annot k ->
             let tag = BellName.tag2instrs_var annot in
             let bd =
               tag,
               lazy begin
                 E.EventSet.filter (pred annot) evts
               end in
             bd::k)
           annots [])

(* Intepreter call *)
    let (opts,_,prog) = O.m
    let withco = opts.ModelOption.co

    let run_interpret test  kfail =
      let run =  I.interpret test kfail in
      fun ks m vb_pp kont res ->
        run ks m vb_pp
          (fun st res ->
            if
              not O.strictskip || StringSet.equal st.I.out_skipped O.skipchecks
            then
              let conc = ks.I.conc in
              kont conc conc.S.fs st.I.out_show st.I.out_flags res
            else res)
          res

(* Enter here *)
    let check_event_structure test conc kfail kont res =
      let pr = lazy (MU.make_procrels E.is_isync conc) in
      let vb_pp =
        if O.showsome && O.verbose > 0 then
          lazy (MU.pp_procrels None (Lazy.force pr))
        else
          lazy [] in
      let relevant e = not (E.is_reg_any e && E.is_commit e) in
      let evts = E.EventSet.filter relevant conc.S.str.E.events in
      let id =
        lazy begin
          E.EventRel.of_list
            (List.rev_map
               (fun e -> e,e)
               (E.EventSet.elements evts))
        end in
      let unv = lazy begin E.EventRel.cartesian evts evts  end in
      let ks = { I.id; unv; evts; conc;} in
(* Initial env *)
      let m =
        I.add_rels
          I.init_env_empty
          ["id",id;
            "loc", lazy begin
              E.EventRel.restrict_rel E.same_location (Lazy.force unv)
            end;
            "int",lazy begin
              E.EventRel.restrict_rel E.same_proc (Lazy.force unv)
            end ;
            "ext",lazy begin
              E.EventRel.restrict_rel
                (fun e1 e2 -> not (E.same_proc e1 e2)) (Lazy.force unv)
            end ;
           "rmw",lazy conc.S.atomic_load_store;
           "po", lazy  begin
             E.EventRel.filter
               (fun (e1,e2) -> relevant e1 && relevant e2)
               conc.S.po
           end ;
           "addr", lazy (Lazy.force pr).S.addr;
           "data", lazy (Lazy.force pr).S.data;
           "ctrl", lazy (Lazy.force pr).S.ctrl;
           "rf", lazy (Lazy.force pr).S.rf;
           "fromto", lazy conc.S.fromto;
          ] in
      let m =
        I.add_sets m
          (List.map
             (fun (k,p) -> k,lazy (E.EventSet.filter p evts))
          [
           "R", E.is_mem_load;
           "W", E.is_mem_store;
           "M", E.is_mem;
	   "F", E.is_barrier;
	   "I", E.is_mem_store_init;
	   "IW", E.is_mem_store_init;
	   "FW",
           (let ws = lazy (U.make_write_mem_finals conc) in
           fun e -> E.EventSet.mem e (Lazy.force ws));
         ]) in
      let m =
        I.add_sets m
          (List.map
             (fun (k,a) ->
               k,lazy (E.EventSet.filter (fun e -> a e.E.action) evts))
	  E.Act.arch_sets) in
(* Define empty fence relation
   (for the few models that apply to several archs) *)
      let m = I.add_rels m
         [
(* PTX fences *)
	   "membar.cta",lazy E.EventRel.empty;
	   "membar.gl", lazy E.EventRel.empty;
	   "membar.sys",lazy E.EventRel.empty;
        ] in
(* Override arch specific fences *)
      let m =
        I.add_rels m
          (List.map
             (fun (k,p) ->
               let pred e = p e.E.action in
               k,lazy (U.po_fence_po conc.S.po pred))
             E.Act.arch_fences) in
(* Event sets from bell_info *)
      let m =
        match bell_info with
        | None -> m
        | Some bi ->
            let m =
              add_bell_events m
                (fun annot e -> E.Act.annot_in_list annot e.E.action)
                evts
                (BellModel.get_mem_annots bi) in
            let open MiscParser in
            begin match test.Test.extra_data with
              (* No region in test, no event sets *)
              | NoExtra|BellExtra {BellInfo.regions=None;_} -> m
              | BellExtra {BellInfo.regions=Some regions;_} ->
                  add_bell_events m
                    (fun region e -> match E.Act.location_of e.E.action with
                    | None -> false
                    | Some x ->
                       List.mem (E.Act.A.pp_location x, region) regions)
                    evts
                    (BellModel.get_region_sets bi)
              | CExtra _ -> assert false (* This is Bell, not C *)
            end in
(* Scope relations from bell info *)
      let m =
        match bell_info with
        | None -> m
        | Some _ ->
            let scopes =
              let open MiscParser in
              match test.Test.extra_data with
              | NoExtra|CExtra _ ->
                  assert false (* must be here as, O.bell_mode_info is *)
              | BellExtra tbi -> tbi.BellInfo.scopes in
            begin match scopes with
 (* If no scope definition in test, do not build relations, will fail
    later if the model attempts to use scope relations *)
            | None -> m
 (* Otherwise, build scope relations *)
            | Some scopes ->
                let rs = U.get_scope_rels evts scopes in
                I.add_rels m
                  (List.map
                     (fun (scope,r) -> BellName.tag2rel_var scope,lazy r)
                     rs)
            end in
(*
                I.add_rels m
                  (List.map
                     (fun scope ->
                       BellName.tag2rel_var scope,
                       lazy begin
                         U.int_scope_bell scope scopes (Lazy.force unv)
                       end)
                     (BellModel.get_scope_rels bi))
            end in *) 
(* Now call interpreter, with or without generated co *)
      if withco then
        let process_co co0 res =
          let co = S.tr co0 in
          let fr = U.make_fr conc co in
          let vb_pp =
            if O.showsome then
              lazy (("fr",fr)::("co",co0)::Lazy.force vb_pp)
            else
              lazy [] in
          let m =
            I.add_rels m
              [
               "fr", lazy fr;
               "fre", lazy (U.ext fr); "fri", lazy (U.internal fr);
               "co", lazy co;
               "coe", lazy (U.ext co); "coi", lazy (U.internal co);
	     ] in
          run_interpret test kfail ks m vb_pp kont res in
        U.apply_process_co test  conc process_co res
      else
(*        let m = I.add_rels m ["co0",lazy  conc.S.pco] in *)
        run_interpret test kfail ks m vb_pp kont res
  end
