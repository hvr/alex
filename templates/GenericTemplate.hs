-- -----------------------------------------------------------------------------
-- ALEX TEMPLATE
--
-- This code is in the PUBLIC DOMAIN; you may copy it freely and use
-- it for any purpose whatsoever.

-- -----------------------------------------------------------------------------
-- INTERNALS and main scanner engine

#ifdef ALEX_GHC
#undef __GLASGOW_HASKELL__
#define ALEX_IF_GHC_GT_500 #if __GLASGOW_HASKELL__ > 500
#define ALEX_IF_GHC_LT_503 #if __GLASGOW_HASKELL__ < 503
#define ALEX_IF_GHC_GT_706 #if __GLASGOW_HASKELL__ > 706
#define ALEX_ELIF_GHC_500 #elif __GLASGOW_HASKELL__ == 500
#define ALEX_IF_BIGENDIAN #ifdef WORDS_BIGENDIAN
#define ALEX_ELSE #else
#define ALEX_ENDIF #endif
#define ALEX_DEFINE #define
#endif

#ifdef ALEX_GHC
#define ILIT(n) n#
#define IBOX(n) (I# (n))
#define FAST_INT Int#
-- Do not remove this comment. Required to fix CPP parsing when using GCC and a clang-compiled alex.
ALEX_IF_GHC_GT_706
ALEX_DEFINE GTE(n,m) (tagToEnum# (n >=# m))
ALEX_DEFINE EQ(n,m) (tagToEnum# (n ==# m))
ALEX_ELSE
ALEX_DEFINE GTE(n,m) (n >=# m)
ALEX_DEFINE EQ(n,m) (n ==# m)
ALEX_ENDIF
#define PLUS(n,m) (n +# m)
#define MINUS(n,m) (n -# m)
#define TIMES(n,m) (n *# m)
#define NEGATE(n) (negateInt# (n))
#define IF_GHC(x) (x)
#else
#define ILIT(n) (n)
#define IBOX(n) (n)
#define FAST_INT Int
#define GTE(n,m) (n >= m)
#define EQ(n,m) (n == m)
#define PLUS(n,m) (n + m)
#define MINUS(n,m) (n - m)
#define TIMES(n,m) (n * m)
#define NEGATE(n) (negate (n))
#define IF_GHC(x)
#endif

#ifdef ALEX_GHC
data AlexAddr = AlexA# Addr#
-- Do not remove this comment. Required to fix CPP parsing when using GCC and a clang-compiled alex.
ALEX_IF_GHC_LT_503
uncheckedShiftL# = shiftL#
ALEX_ENDIF

{-# INLINE alexIndexInt16OffAddr #-}
alexIndexInt16OffAddr (AlexA# arr) off =
ALEX_IF_BIGENDIAN
  narrow16Int# i
  where
        i    = word2Int# ((high `uncheckedShiftL#` 8#) `or#` low)
        high = int2Word# (ord# (indexCharOffAddr# arr (off' +# 1#)))
        low  = int2Word# (ord# (indexCharOffAddr# arr off'))
        off' = off *# 2#
ALEX_ELSE
  indexInt16OffAddr# arr off
ALEX_ENDIF
#else
alexIndexInt16OffAddr arr off = arr ! off
#endif

#ifdef ALEX_GHC
{-# INLINE alexIndexInt32OffAddr #-}
alexIndexInt32OffAddr (AlexA# arr) off = 
ALEX_IF_BIGENDIAN
  narrow32Int# i
  where
   i    = word2Int# ((b3 `uncheckedShiftL#` 24#) `or#`
		     (b2 `uncheckedShiftL#` 16#) `or#`
		     (b1 `uncheckedShiftL#` 8#) `or#` b0)
   b3   = int2Word# (ord# (indexCharOffAddr# arr (off' +# 3#)))
   b2   = int2Word# (ord# (indexCharOffAddr# arr (off' +# 2#)))
   b1   = int2Word# (ord# (indexCharOffAddr# arr (off' +# 1#)))
   b0   = int2Word# (ord# (indexCharOffAddr# arr off'))
   off' = off *# 4#
ALEX_ELSE
  indexInt32OffAddr# arr off
ALEX_ENDIF
#else
alexIndexInt32OffAddr arr off = arr ! off
#endif

#ifdef ALEX_GHC

ALEX_IF_GHC_LT_503
quickIndex arr i = arr ! i
ALEX_ELSE
-- GHC >= 503, unsafeAt is available from Data.Array.Base.
quickIndex = unsafeAt
ALEX_ENDIF
#else
quickIndex arr i = arr ! i
#endif

-- -----------------------------------------------------------------------------
-- Main lexing routines

data AlexReturn a
  = AlexEOF
  | AlexError  !AlexInput
  | AlexSkip   !AlexInput !Int
  | AlexToken  !AlexInput !Int a

-- alexScan :: AlexInput -> StartCode -> AlexReturn a
alexScan input IBOX(sc)
  = alexScanUser undefined input IBOX(sc)

alexScanUser user input IBOX(sc)
  = case alex_scan_tkn user input ILIT(0) input sc AlexNone of
	(AlexNone, input') ->
		case alexGetByte input of
			Nothing -> 
#ifdef ALEX_DEBUG
				   trace ("End of input.") $
#endif
				   AlexEOF
			Just _ ->
#ifdef ALEX_DEBUG
				   trace ("Error.") $
#endif
				   AlexError input'

	(AlexLastSkip input'' len, _) ->
#ifdef ALEX_DEBUG
		trace ("Skipping.") $ 
#endif
		AlexSkip input'' len

	(AlexLastAcc k input''' len, _) ->
#ifdef ALEX_DEBUG
		trace ("Accept.") $ 
#endif
		AlexToken input''' len k


-- Push the input through the DFA, remembering the most recent accepting
-- state it encountered.

alex_scan_tkn user orig_input len input s last_acc =
  input `seq` -- strict in the input
  let 
	new_acc = (check_accs (alex_accept `quickIndex` IBOX(s)))
  in
  new_acc `seq`
  case alexGetByte input of
     Nothing -> (new_acc, input)
     Just (c, new_input) -> 
#ifdef ALEX_DEBUG
      trace ("State: " ++ show IBOX(s) ++ ", char: " ++ show c) $
#endif
      case fromIntegral c of { IBOX(ord_c) ->
        let
                base   = alexIndexInt32OffAddr alex_base s
                offset = PLUS(base,ord_c)
                check  = alexIndexInt16OffAddr alex_check offset
		
                new_s = if GTE(offset,ILIT(0)) && EQ(check,ord_c)
			  then alexIndexInt16OffAddr alex_table offset
			  else alexIndexInt16OffAddr alex_deflt s
	in
        case new_s of
	    ILIT(-1) -> (new_acc, input)
		-- on an error, we want to keep the input *before* the
		-- character that failed, not after.
    	    _ -> alex_scan_tkn user orig_input (if c < 0x80 || c >= 0xC0 then PLUS(len,ILIT(1)) else len)
                                                -- note that the length is increased ONLY if this is the 1st byte in a char encoding)
			new_input new_s new_acc
      }
  where
	check_accs (AlexAccNone) = last_acc
	check_accs (AlexAcc a  ) = AlexLastAcc a input IBOX(len)
	check_accs (AlexAccSkip) = AlexLastSkip  input IBOX(len)
#ifndef ALEX_NOPRED
	check_accs (AlexAccPred a predx rest)
	   | predx user orig_input IBOX(len) input
	   = AlexLastAcc a input IBOX(len)
	   | otherwise
	   = check_accs rest
	check_accs (AlexAccSkipPred predx rest)
	   | predx user orig_input IBOX(len) input
	   = AlexLastSkip input IBOX(len)
	   | otherwise
	   = check_accs rest
#endif

data AlexLastAcc a
  = AlexNone
  | AlexLastAcc a !AlexInput !Int
  | AlexLastSkip  !AlexInput !Int

instance Functor AlexLastAcc where
    fmap f AlexNone = AlexNone
    fmap f (AlexLastAcc x y z) = AlexLastAcc (f x) y z
    fmap f (AlexLastSkip x y) = AlexLastSkip x y

data AlexAcc a user
  = AlexAccNone
  | AlexAcc a
  | AlexAccSkip
#ifndef ALEX_NOPRED
  | AlexAccPred a   (AlexAccPred user) (AlexAcc a user)
  | AlexAccSkipPred (AlexAccPred user) (AlexAcc a user)

type AlexAccPred user = user -> AlexInput -> Int -> AlexInput -> Bool

-- -----------------------------------------------------------------------------
-- Predicates on a rule

alexAndPred p1 p2 user in1 len in2
  = p1 user in1 len in2 && p2 user in1 len in2

--alexPrevCharIsPred :: Char -> AlexAccPred _ 
alexPrevCharIs c _ input _ _ = c == alexInputPrevChar input

alexPrevCharMatches f _ input _ _ = f (alexInputPrevChar input)

--alexPrevCharIsOneOfPred :: Array Char Bool -> AlexAccPred _ 
alexPrevCharIsOneOf arr _ input _ _ = arr ! alexInputPrevChar input

--alexRightContext :: Int -> AlexAccPred _
alexRightContext IBOX(sc) user _ _ input = 
     case alex_scan_tkn user input ILIT(0) input sc AlexNone of
	  (AlexNone, _) -> False
	  _ -> True
	-- TODO: there's no need to find the longest
	-- match when checking the right context, just
	-- the first match will do.
#endif

-- used by wrappers
iUnbox IBOX(i) = i
