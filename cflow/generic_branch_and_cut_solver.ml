(**
  * generic_branch_and_cup_solver.ml
  *
  * Causal flow compression: a module for KaSim 
  * Jérôme Feret, projet Abstraction, INRIA Paris-Rocquencourt
  * Jean Krivine, Université Paris-Diderot, CNRS 
  * 
  * KaSim
  * Jean Krivine, Université Paris-Diderot, CNRS 
  *  
  * Creation: 29/08/2011
  * Last modification: 19/03/2012
  * * 
  * Some parameters references can be tuned thanks to command-line options
  * other variables has to be set before compilation   
  *  
  * Copyright 2011 Institut National de Recherche en Informatique et   
  * en Automatique.  All rights reserved.  This file is distributed     
  * under the terms of the GNU Library General Public License *)


module Solver = 
struct 
  module PH= Propagation_heuristics.Propagation_heuristic 
(*Blackboard_with_heuristic*)
    
  let combine_output o1 o2 = 
    if PH.B.is_ignored o2 then o1 else o2 
      
  let p n = 
    if n mod 10000 = 0 
    then true
    else if n<10000 && n mod 1000 = 0 
    then true
    else if n<1000 && n mod 100 = 0 
    then true 
    else if n<100 && n mod 10 = 0 
    then true 
    else if n<10 then true 
    else false 

  let tmp = ref true 

  let p n = 
    let bool = p n in 
    if (!tmp) = bool 
    then 
      false 
    else 
      let _ = tmp:=bool in 
      bool 

let rec propagate parameter handler error instruction_list propagate_list blackboard = 
    let n = (PH.B.get_n_unresolved_events blackboard) in 
    let _ =
      if p n then 
        let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "Propagate %i %i %i %i \n" (List.length instruction_list) (List.length propagate_list) (PH.B.get_n_unresolved_events blackboard) (PH.B.get_stack_depth blackboard) in 
        let _ = flush parameter.PH.B.PB.K.H.out_channel_err
        in () 
    in 
    match instruction_list 
    with 
      | t::q ->
        begin 
          let error,blackboard,instruction_list,propagate_list,assign_result = PH.apply_instruction parameter handler error blackboard t q propagate_list in 
          if PH.B.is_failed assign_result 
          then 
            error,blackboard,assign_result 
          else 
            propagate parameter handler error instruction_list propagate_list blackboard
        end
      | [] -> 
        begin
          match propagate_list 
          with 
            | t::q -> 
              let error,blackboard,instruction_list,propagate_list,assign_result = PH.propagate parameter handler error blackboard t instruction_list q in 
                    if PH.B.is_failed assign_result 
                    then 
                      error,blackboard,assign_result 
                    else 
                      propagate parameter handler error instruction_list propagate_list blackboard
            | [] -> error,blackboard,PH.B.success
        end 
          
	  
  let rec branch_over_assumption_list parameter handler error list blackboard = 
    match list 
    with 
	  | [] ->
             let n = (PH.B.get_n_unresolved_events blackboard) in 
             let _ =
               if n mod 10000 = 0 then 
                 let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "Fail %i \n" (PH.B.get_n_unresolved_events blackboard) in 
                 let _ = flush parameter.PH.B.PB.K.H.out_channel_err
                 in ()
             in 
                 error,blackboard,PH.B.fail
	  | head::tail -> 
	    begin
	      let error,blackboard = PH.B.branch parameter handler error blackboard in
	      let error,blackboard,output = propagate parameter handler error [head] [] blackboard in
	      if PH.B.is_failed output 
              then 
                let error,blackboard = PH.B.reset_last_branching parameter handler error blackboard in 
                branch_over_assumption_list parameter handler error tail blackboard 
              else 
                let error,blackboard,output = iter parameter handler error blackboard in 
                if PH.B.is_failed output 
                then 
                  let error,blackboard = PH.B.reset_last_branching parameter handler error blackboard in 
                  let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "FAIL\n" in 
                  branch_over_assumption_list parameter handler error tail blackboard 
                else 
                  error,blackboard,output 
	    end
	      
  and iter parameter handler error blackboard = 
    let error,bool = PH.B.is_maximal_solution parameter handler error blackboard in
    if bool 
    then 
      error,blackboard,PH.B.success 
    else
       let n = (PH.B.get_n_unresolved_events blackboard) in 
       let _ =
         if n mod 10000 = 0 then 
           let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "Branch %i \n" (PH.B.get_n_unresolved_events blackboard) in 
           let _ = flush parameter.PH.B.PB.K.H.out_channel_err
           in () 
       in 
       let error,list = PH.next_choice parameter handler error blackboard in
      branch_over_assumption_list parameter handler error list blackboard 
    
  let compress parameter handler error blackboard list_order list_eid =
    let error,blackboard = PH.B.branch parameter handler error blackboard in 
    let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "Trying to Cut\n" in 
    let _ = flush parameter.PH.B.PB.K.H.out_channel_err in 
    let error,blackboard,result_wo_compression,events_to_remove  = PH.B.cut parameter handler error blackboard list_eid  in 
    let result_wo_compression = 
      if 
        Parameter.get_causal_trace parameter.PH.B.PB.K.H.compression_mode 
      then 
        Some result_wo_compression 
      else 
        None 
    in 
    let error,forbidden_events = PH.forbidden_events parameter handler error events_to_remove in 
    let _ = 
      Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "Start cutting\n" in 
    let _ = 
      flush parameter.PH.B.PB.K.H.out_channel_err
    in 
    let error,blackboard,output = 
      propagate parameter handler error forbidden_events [] blackboard  
    in 
    let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "After Causal Cut  %i \n" (PH.B.get_n_unresolved_events blackboard) in 
    let _ = 
      flush parameter.PH.B.PB.K.H.out_channel 
    in 
    let error,blackboard,output = 
      propagate parameter handler error list_order [] blackboard 
    in 
    let _ = Printf.fprintf parameter.PH.B.PB.K.H.out_channel_err "After observable propagation  %i \n" (PH.B.get_n_unresolved_events blackboard) in 
    let _ = 
      flush parameter.PH.B.PB.K.H.out_channel 
    in 
    let error,blackboard,output = iter parameter handler error blackboard 
    in 
    error,blackboard,output,result_wo_compression 
end 
  
