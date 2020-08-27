module QPModelGurobi

export gurobi

using Gurobi
using QuadraticModels
using NLPModels
using SolverTools
using LinearAlgebra
using SparseArrays

const gurobi_statuses = Dict(:loaded => :unknown,
                             :optimal => :acceptable,
                            :infeasible => :infeasible,
                            :inf_or_unbd => :infeasible,
                            :unbounded => :unbounded,
                            :cutoff => :exception,
                            :iteration_limit => :max_iter,
                            :node_limit => ::exception,
                            :time_limit => :max_time,
                            :solution_limit => :exception,
                            :interrupted => :user,
                            :numeric => :exception,
                            :suboptimal => :exception,
                            :inprogress => :exception,
                            :user_obj_limit => :exception)


function createQuadraticModel(qpdata)
    return QuadraticModel(qpdata.c, qpdata.qrows, qpdata.qcols, qpdata.qvals,
                        Arows=qpdata.arows, Acols=qpdata.acols, Avals=qpdata.avals,
                        lcon=qpdata.lcon, ucon=qpdata.ucon, lvar=qpdata.lvar, uvar=qpdata.uvar,
                        c0=qpdata.c0)
end


function gurobi(QM; method=2, kwargs...)

    env = Gurobi.Env()
    # -1=automatic, 0=primal simplex, 1=dual simplex, 2=barrier,
    # 3=concurrent, 4=deterministic concurrent, 5=deterministic concurrent simplex.
    # default to barrier
    setparam!(env, "Method", method)
    kwargs = Dict(kwargs)
    for (k, v) in kwargs
        if k==:presolve
            setparam!(env, "Presolve", v) # 0 = no presolve
        elseif k==:scaling
            setparam!(env, "ScaleFlag", v) # 0 = no scaling
        elseif k==:crossover
            setparam!(env, "Crossover", v) # 0 = no crossover
        end
    end

    T = eltype(QM.data.Avals)
    beq, Aeqrows, Aeqcols, Aeqvals = zeros(T,0), zeros(Int, 0), zeros(Int, 0), zeros(T, 0)
    b, Arows, Acols, Avals = zeros(T,0) ,zeros(Int, 0), zeros(Int, 0), zeros(T, 0)
    first_irow = 1
    c_eq = 0
    c_ineq = 0
    last_irow = 0
    p = sortperm(QM.data.Arows)

    for i=1:length(QM.meta.lcon)
        if @views QM.data.Arows[p][last_irow+1] == i
            first_irow = last_irow + 1
            last_irow = @views first_irow-1+findlast(QM.data.Arows[p][first_irow:end] .== i)
            if QM.meta.lcon[i] == QM.meta.ucon[i]
                c_eq += 1
                push!(beq, QM.meta.lcon[i])
                append!(Aeqcols, QM.data.Acols[p][first_irow:last_irow])
                append!(Aeqrows, c_eq.*ones(Int, last_irow-first_irow+1))
                append!(Aeqvals, QM.data.Avals[p][first_irow:last_irow])
            elseif QM.meta.lcon[i] == -Inf && QM.meta.ucon[i] != Inf
                c_ineq += 1
                push!(b, QM.meta.ucon[i])
                append!(Acols, @views QM.data.Acols[p][first_irow:last_irow])
                append!(Arows, @views c_ineq.*ones(Int, last_irow-first_irow+1))
                append!(Avals, @views QM.data.Avals[p][first_irow:last_irow])
            elseif QM.meta.lcon[i] != -Inf && QM.meta.ucon[i] == Inf
                c_ineq += 1
                push!(b, -QM.meta.lcon[i])
                append!(Acols, @views QM.data.Acols[p][first_irow:last_irow])
                append!(Arows, @views c_ineq.*ones(Int, last_irow-first_irow+1))
                append!(Avals, @views .-QM.data.Avals[p][first_irow:last_irow])
            end
        end

    end
    Aeq = sparse(Aeqrows, Aeqcols, Aeqvals, length(beq), QM.meta.nvar)
    A = sparse(Arows, Acols, Avals, length(b), QM.meta.nvar)
    H = sparse(QM.data.Hrows, QM.data.Hcols, QM.data.Hvals)
    H = Matrix(Symmetric(H, :L))

    model = gurobi_model(env; f = QM.data.c, H = H,
                        A = A, b = b, Aeq = Aeq, beq = beq,
                        lb = QM.meta.lvar, ub = QM.meta.uvar)
     # run optimization
    optimize(model)

    y = zeros(length(beq))
    for i=1:n
        y[i] = Gurobi.get_dblattrelement(model, "Pi", i)
    end
    s = zeros(length(f)) # s_l - s_u
    for i=1:m
        s[i] = Gurobi.get_dblattrelement(model, "RC", i)
    end

    optim_info = get_optiminfo(model)
    x = get_solution(model)
    stats = GenericExecutionStats(get(gurobi_statuses, optim_info.status, :unknown),
                                  SM, solution = x,
                                  objective = get_objval(model),
                                  iter = Gurobi.get_intattr(model,"BarIterCount"),
                                  primal_feas = Gurobi.get_dblattr(model, "ConstrResidual"),
                                  dual_feas = Gurobi.get_dblattr(model, "DualResidual"),
                                  solver_specific = Dict(:multipliers => y,
                                                         :RC => s),
                                  elapsed_time = optim_info.runtime)
    return stats
end


function gurobi(qpdata::QPSData; method=2, kwarg...)
    return gurobi(createQuadraticModel(qpdata); method=2, kwargs...)
end

end
