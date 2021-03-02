(* Types *)

type var = string
type typ = Type.typ

and func = typ list -> value list -> value

and value =
  | Null
  | Bool of bool
  | Byte of char
  | Int of int32
  | Float of float
  | Text of string
  | Tup of value list
  | Array of value ref list
  | Obj of typ * (Type.sort * value ref) Env.Map.t ref
  | Func of func
  | Class of Type.cls * func


(* Comparison *)

let is_ref = function
  | Null | Bool _ | Byte _ | Int _ | Float _ | Text _ -> false
  | Tup _ -> false
  | Array _ | Obj _ | Func _ | Class _ -> true


let rec eq v1 v2 =
  v1 == v2 ||
  match v1, v2 with
  | Tup vs1, Tup vs2 ->
    List.length vs1 = List.length vs2 && List.for_all2 eq vs1 vs2
  | v1, v2 when is_ref v1 && is_ref v2 -> v1 == v2
  | v1, v2 when not (is_ref v1) && not (is_ref v2) -> v1 = v2
  | _, _ -> false


(* Default *)

let rec default = function
  | Type.Var _ -> assert false
  | Type.(Null | Obj | Array _ | Func _ | Inst _ | Class _) -> Null
  | Type.Bool -> Bool false
  | Type.Byte -> Byte '\x00'
  | Type.Int -> Int 0l
  | Type.Float -> Float 0.0
  | Type.Text -> Text ""
  | Type.Tup ts -> Tup (List.map default ts)


(* Printing *)

let list f xs = String.concat ", " (List.map f xs)

let rec to_string = function
  | Null -> "null"
  | Bool b -> string_of_bool b
  | Byte c -> Printf.sprintf "0x%02x" (Char.code c)
  | Int i -> Int32.to_string i
  | Float z -> string_of_float z
  | Text t -> "\"" ^ String.escaped t ^ "\""
  | Tup vs -> "(" ^ list to_string vs ^ ")"
  | Array vs -> "[" ^ list to_string (List.map (!) vs) ^ "]"
  | Obj (t, _) -> "(new " ^ Type.to_string t ^ ")"
  | Func _ -> "func"
  | Class _ -> "class"