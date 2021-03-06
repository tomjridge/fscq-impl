module Interpreter where

import Prog
import qualified Disk
-- import qualified System.Exit
-- import qualified System.Random

-- crashRandom :: IO Int
-- crashRandom = System.Random.getStdRandom (System.Random.randomR (1, 20))

-- maybeCrash :: IO ()
-- maybeCrash = do
--   x <- crashRandom
--   -- if x == 1
--   if x == 0
--   then
--     do
--       putStrLn "CRASH!"
--       System.Exit.exitFailure
--   else
--     return ()

verbose :: Bool
verbose = False

debugmsg :: String -> IO ()
debugmsg s =
  if verbose then
    putStrLn s
  else
    return ()

run_dcode :: Disk.DiskState -> Prog.Coq_prog a -> IO a
run_dcode _ (Done r) = do
  debugmsg $ "Done"
  return r
run_dcode ds (Read a rx) = do
  debugmsg $ "Read " ++ (show a)
  val <- Disk.read_disk ds a
  run_dcode ds $ rx val
run_dcode ds (Write a v rx) = do
  debugmsg $ "Write " ++ (show a) ++ " " ++ (show v)
  Disk.write_disk ds a v
  run_dcode ds $ rx ()
run_dcode ds (Sync a rx) = do
  debugmsg $ "Sync " ++ (show a)
  Disk.sync_disk ds a
  run_dcode ds $ rx ()
run_dcode ds (Trim a rx) = do
  debugmsg $ "Trim " ++ (show a)
  Disk.trim_disk ds a
  run_dcode ds $ rx ()

run :: Disk.DiskState -> ((a -> Prog.Coq_prog a) -> Prog.Coq_prog a) -> IO a
run ds p = run_dcode ds $ p (\x -> Prog.Done x)
