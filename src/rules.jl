const discount = 0.99f0
const inv_discount = 1/discount

const VALIDATE=false;

const limits = @SVector [7, 8]

const Pos = SVector{2, Int8}

struct PlayerState
  ball::Pos
  pieces::SMatrix{2,5, Int8}
end
@functor PlayerState

struct State
  player::Int
  positions::SVector{2, PlayerState}
end
@functor State (positions,)

# Base.:(==)(a::State, b::State) = foldmap(&, true, a, b) do a, b
#   all(a .== b)
# end

# Base.hash(a::State, u::UInt) = foldmap(identity, flip(hash), h, a)

const start_state = State(1, 
  SVector{2}([
    PlayerState(
      SVector{2}([4,1]),
      SMatrix{2,5}(Int8[collect(2:6) fill(1, 5)]')),
    PlayerState(
      SVector{2}([4,8]),
      SMatrix{2,5}(Int8[collect(2:6) fill(8, 5)]'))
      ]))
      
      
function is_terminal(state)
  state.positions[1].ball[2] == limits[2] || state.positions[2].ball[2] == 1
end

function occupied(state::State, y)
  mapreduce(|, state.positions) do ps
    any(encode(ps.pieces) .== encode(y))
  end
end

struct PotentialMove
  y::Pos
  norm::Int8
end

function lub(a::PotentialMove, b::PotentialMove)
  if a.norm < b.norm
    return a
  end
  if a.norm == b.norm
    error("Two pieces at the same position: ", a.y, ", ", b.y)
  end
  return b
end

const PieceIx = UInt8
const Action = Tuple{PieceIx, Pos}

function piece_actions(st::State)
  actions = Vector{Action}()
  ball_pos = st.positions[st.player].ball
  for i in 1:5
    x = st.positions[st.player].pieces[:, i]
    if any(x .!= ball_pos)
      for move in (SVector{2}([1,2]), SVector{2}([2,1]))
        for d1 in (-1, 1)
          for d2 in (-1, 1)
            pos = x .+ move .* (@SVector [d1, d2])
            if all(pos .>= 1) && all(pos .<= limits) && !occupied(st, pos)
              push!(actions, (i, pos))
            end
          end
        end
      end
    end
  end
  actions
end


function ball_actions(st::State)
  y = st.positions[st.player].ball
  passes = Set{Pos}([y])
  balls = Pos[y]
  while length(balls) > 0
    x = pop!(balls)
    for move in pass_actions(st, x)
      yy = move.y
      if yy ??? passes 
        push!(passes, yy)
        push!(balls, yy)
      end
    end
  end
  pop!(passes, y)
  Action[(UInt8(6), p) for p in passes]
end

next_player(player::Int) = (1 ??? (player - 1)) + 1

const Dir = Pos

function encode(pieces::AbstractMatrix)
  (pieces[2,:] .- 1) .* limits[1] .+ pieces[1,:]
end

encode(piece::AbstractVector) = (piece[2] - 1) * limits[1] + piece[1]

function assert_valid_state(st::State)
  for i in (1,2)
    encoded = encode(st.positions[i].pieces)
    @assert length(encoded) == length(unique(encoded))
    ball_pos = encode(st.positions[i].ball[:, na])
    @assert ball_pos[1] in encoded
    @assert all(st.positions[i].pieces .>= 1)
    @assert all(st.positions[i].pieces .<= limits[:, na])
  end
end

function pass_actions(st::State, x::Pos)
  if VALIDATE
    assert_valid_state(st)
  end
  moves = Dict{Dir, PotentialMove}()
  for player in (st.player, next_player(st.player))
    vecs = (st.positions[player].pieces .- x[:, na])::SMatrix{2, 5, Int8}
    absvecs = abs.(vecs)::SMatrix{2, 5, Int8}
    diagonals = (absvecs[1, :] .== absvecs[2, :])::SVector{5, Bool}
    verticals = vecs[1, :] .== 0
    horizontals = vecs[1, :] .== 0
    norms = maximum(absvecs; dims=1)[1, :]::SVector{5, Int8}
    nz = (norms .> 0)::SVector{5, Bool}
    valid = ((diagonals .| verticals .| horizontals) .& nz)::SVector{5, Bool}
    normsv = norms[valid]::Vector{Int8}
    units = (vecs[:, valid] .?? normsv[na, :])::Matrix{Int8}
    y = (st.positions[player].pieces[:, valid])::Matrix{Int8}
    if player == st.player
      for i in 1:size(units, 2)
        u = SVector{2}(units[:, i])
        if haskey(moves, u)
          moves[u] = lub(moves[u], PotentialMove(y[:,i], normsv[i]))
        else
          moves[u] = PotentialMove(y[:,i], normsv[i])
        end
      end
    else
      for i in 1:size(units, 2)
        u = SVector{2}(units[:, i])
        if haskey(moves, u) && normsv[i] < moves[u].norm
          pop!(moves, u)
        end
      end
    end
  end
  values(moves)
end

function actions(st::State)::Vector{Action}
  acts = piece_actions(st)
  append!(acts, ball_actions(st))
  acts
end

struct ValuedAction
  action::Action
  value::Float32
end

apply_action(st::State, a::ValuedAction) = apply_action(st, a.action)

function apply_action(st::State, (pieceix, pos)::Action)
  if pieceix < 6
    pieces = (st.positions[st.player].pieces)::SMatrix{2, 5, Int8}
    ix = LinearIndices(pieces)
    pmat = setindex(setindex(pieces, pos[1], ix[1, pieceix]), pos[2], ix[2, pieceix])
    @set st.positions[st.player].pieces = pmat
  else
    @set st.positions[st.player].ball = pos
  end
end

struct EndState
  winner::Union{Int8, Nothing}
  st::State
  steps::Int
  states::Vector{State}
end

function simulate(st::State, players; steps=300, log=false, track=false)
  player_ixs = st.player == 1 ? (0=>1,1=>2) : (0=>2,1=>1)
  simulate_(st, players, player_ixs, steps ?? 2, log, track)
end

@unroll function simulate_(st::State, players, player_ixs, steps, log, track)
  states = Vector{State}()
  for nsteps in 0:steps
    @unroll for (substep, player) in player_ixs
      st = @set st.player = player
      if is_terminal(st)
        return EndState(next_player(player), st, 2 * nsteps + substep, states)
      end
      action = players[player](st)
      if log
        log_action(st, action)
      end
      st = apply_action(st, action)
      if track
        push!(states, st)
      end
    end
  end
  return EndState(nothing, st, steps, states)
end
