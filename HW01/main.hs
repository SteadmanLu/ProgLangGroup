import PA1Helper
import System.Environment (getArgs)
import qualified Data.Set as Set
import Data.Set (Set)


-- Haskell representation of lambda expression
-- data Lexp = Atom String | Lambda String Lexp | Apply Lexp  Lexp 

-- Free Variables

freeVars:: Lexp -> Set String
freeVars (Atom v) = Set.singleton v
freeVars (Lambda var body) = Set.delete var (freeVars body)
freeVars (Apply exp1 exp2) = Set.union (freeVars exp1) (freeVars exp2)

-- Fresh variable generation (for alpha renaming)
freshVar :: String -> Set String -> String
freshVar base avoid
    |candidate `Set.notMember` avoid = candidate
    |otherwise = freshVar candidate avoid
    where candidate = base ++ "1"

-- Substitution: subset x n e == e[x := n] ("replace free x in e with n")
subst :: String -> Lexp -> Lexp -> Lexp
subst x n (Atom v)
    | v == x = n            -- Repace the variable itself
    | otherwise = Atom v    -- different variable leave it alone

subst x n (Apply e1 e2) = Apply (subst x n e1) (subst x n e2) -- Apply the substitution to both sides of the application

subst x n (Lambda v body)
    |v == x = Lambda v body -- If the variable is bound, leave it alone
    |v `Set.member` freeVars n =  
        let v'    = freshVar v (Set.union (freeVars n) (freeVars body)) 
            body' = subst v (Atom v') body   -- rename v -> v' inside body
        in Lambda v' (subst x n body')
    |otherwise = Lambda v (subst x n body) -- safe to substitute directly into the body


-- Eta reduction
stepEta :: Lexp -> Maybe Lexp
stepEta (Lambda x (Apply f (Atom y)))
  | x == y && x `Set.notMember` freeVars f =
      Just f   -- direct eta-redex at this node

stepEta (Lambda x body) =
  case stepEta body of
    Just body' -> Just (Lambda x body')
    Nothing    -> Nothing

stepEta (Apply e1 e2) =
  case stepEta e1 of
    Just e1' -> Just (Apply e1' e2)
    Nothing  -> case stepEta e2 of
                  Just e2' -> Just (Apply e1 e2')
                  Nothing  -> Nothing

stepEta (Atom _) = Nothing
 
-- | Repeatedly apply stepEta until no eta-redex remains.
etaNormalize :: Lexp -> Lexp
etaNormalize e = case stepEta e of
  Just e' -> etaNormalize e'
  Nothing -> e

betaReduce :: Lexp -> Lexp
betaReduce (Apply (Lambda var body) arg) =
    subst var arg body

betaReduce (Apply e1 e2) =
    Apply (betaReduce e1) (betaReduce e2)

betaReduce (Lambda var body) =
    Lambda var (betaReduce body)

betaReduce e = e

-- | Repeatedly apply betaReduce until the expression stops changing
betaNormalize :: Lexp -> Lexp
betaNormalize e =
  let e' = betaReduce e
  in if e' == e then e else betaNormalize e'

-- Given a filename and function for reducing lambda expressions,
-- reduce all valid lambda expressions in the file and output results.
-- runProgram :: String -> (Lexp -> Lexp) -> IO ()

-- This is the identity function for the Lexp datatype, which is
-- used to illustrate pattern matching with the datatype. "_" was
-- used since I did not need to use bound variable. For your code,
-- however, you can replace "_" with an actual variable name so you
-- can use the bound variable. The "@" allows you to retain a variable
-- that represents the entire structure, while pattern matching on
-- components of the structure.
id' :: Lexp -> Lexp
id' v@(Atom _) = v
id' lexp@(Lambda _ _) = lexp
id' lexp@(Apply _ _) = lexp 

-- You will need to write a reducer that does something more than
-- return whatever it was given, of course!

reducer :: Lexp -> Lexp
reducer lexp = betaNormalize lexp

-- Entry point of program
main = do
    args <- getArgs
    let inFile = case args of { x:_ -> x; _ -> "input.lambda" }
    let outFile = case args of { x:y:_ -> y; _ -> "output.lambda"}
    -- id' simply returns its input, so runProgram will result
    -- in printing each lambda expression twice. 
    runProgram inFile outFile reducer