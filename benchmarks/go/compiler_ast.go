package main

import "fmt"

type Expr interface{}

type ELit struct {
	value int
}

type EVar struct {
	id int
}

type EAdd struct {
	left  Expr
	right Expr
}

type EMul struct {
	left  Expr
	right Expr
}

type ELet struct {
	name  int
	value Expr
	body  Expr
}

type EIf struct {
	cond Expr
	then Expr
	els  Expr
}

func buildExpr(depth int, seed int) Expr {
	if depth <= 0 {
		if seed%3 == 0 {
			return EVar{seed % 4096}
		}
		return ELit{(seed*17 + 11) % 100000}
	}
	next := seed*3 + depth
	switch depth % 5 {
	case 0:
		return EAdd{buildExpr(depth-1, next), buildExpr(depth-1, next+1)}
	case 1:
		return EMul{buildExpr(depth-1, next), buildExpr(depth-1, next+3)}
	case 2:
		return ELet{seed % 8192, buildExpr(depth-1, next), buildExpr(depth-1, next+5)}
	case 3:
		return EIf{
			buildExpr(depth-1, next),
			buildExpr(depth-2, next+7),
			buildExpr(depth-2, next+11),
		}
	default:
		return EAdd{buildExpr(depth-1, next+13), buildExpr(depth-1, next+17)}
	}
}

func rewriteExpr(expr Expr, pass int) Expr {
	switch e := expr.(type) {
	case ELit:
		return ELit{(e.value + pass*13 + 7) % 1000003}
	case EVar:
		return EVar{(e.id*33 + pass + 19) % 16384}
	case EAdd:
		if pass%7 == 0 {
			return EAdd{rewriteExpr(e.right, pass), rewriteExpr(e.left, pass)}
		}
		return EAdd{rewriteExpr(e.left, pass), rewriteExpr(e.right, pass)}
	case EMul:
		return EMul{rewriteExpr(e.left, pass), rewriteExpr(e.right, pass)}
	case ELet:
		return ELet{(e.name + pass) % 16384, rewriteExpr(e.value, pass), rewriteExpr(e.body, pass+1)}
	case EIf:
		return EIf{
			rewriteExpr(e.cond, pass),
			rewriteExpr(e.then, pass+2),
			rewriteExpr(e.els, pass+3),
		}
	default:
		return ELit{0}
	}
}

func checksumExpr(expr Expr) int {
	switch e := expr.(type) {
	case ELit:
		return e.value + 3
	case EVar:
		return e.id*5 + 7
	case EAdd:
		return 11 + checksumExpr(e.left)*3 + checksumExpr(e.right)
	case EMul:
		return 17 + checksumExpr(e.left) + checksumExpr(e.right)*3
	case ELet:
		return 23 + e.name + checksumExpr(e.value) + checksumExpr(e.body)*5
	case EIf:
		return 31 + checksumExpr(e.cond) + checksumExpr(e.then)*7 + checksumExpr(e.els)
	default:
		return 0
	}
}

func runPipeline(depth int, passes int) int {
	expr := buildExpr(depth, 19)
	checksum := 0
	for pass := 0; pass < passes; pass++ {
		expr = rewriteExpr(expr, pass)
		if pass%8 == 0 {
			checksum += checksumExpr(expr)
		}
	}
	return checksum + checksumExpr(expr)
}

func main() {
	checksum := runPipeline(11, 80)
	fmt.Printf("compiler_ast checksum: %d\n", checksum)
}
