program main
	implicit none
	include 'mpif.h'

	!  A graph in compressed-adjacency-list (CSR) form
	type graph
		integer :: nv ! number of vertices
		integer*8 :: ne ! number of edges
		integer, allocatable :: nbr(:) ! array of neighbors of all vertices
		integer, allocatable :: firstnbr(:) ! index in nbr() of first neighbor of each vtx
	end type graph
	type (graph) total_graph
	type (graph) my_graph

	integer :: i, j, k
    character*32 :: filename=''
    character*32 :: arg
    integer, parameter :: BLOCK=16777216
	integer :: startvtx ! starting vertex
	integer :: nlevelsp
	integer, allocatable :: levelsize(:)
	integer :: reached 
	real :: value
	real :: start_time, start2_time, end_time, elapsed_time, gteps
	character*80 tmp1,tmp2,tmp3

	! variables for mpi
	integer :: myrank, nproc, ierr
	integer, allocatable :: para_range_istart(:), para_range_iend(:)

	do i = 1, command_argument_count()
		call get_command_argument(i, arg)
		if (i.eq.1) filename = trim(arg) 
	enddo

	if (filename.eq.'') then
		write(*,*), 'usage: bfs <filename>'
		call exit(1)
	endif

	call mpi_init( ierr )
	call mpi_comm_rank( MPI_COMM_WORLD, myrank, ierr )
	call mpi_comm_size( MPI_COMM_WORLD, nproc, ierr )

	if (myrank.eq.0) then
		! read the graph from file which is generated by the C program using fwrite 
		call get_time(start_time)
		open(unit=3, file=filename, FORM='UNFORMATTED', access='stream')
		read(3) startvtx, total_graph%ne, total_graph%nv
		allocate(total_graph%nbr(0:total_graph%ne-1))
		allocate(total_graph%firstnbr(0:total_graph%nv))
		if (total_graph%ne.lt.BLOCK) then
        	read(3) total_graph%nbr(0:total_graph%ne-1)
	    else
        	j = (total_graph%ne-1)/BLOCK
        	k = mod((total_graph%ne-1), BLOCK)
        	do i=0, j-1
           		read(3) total_graph%nbr((i*BLOCK):(i+1)*BLOCK-1)
        	enddo
        	if (k.ne.0) read(3) total_graph%nbr(j*BLOCK:(j*BLOCK)+k)
    	endif
		read(3) total_graph%firstnbr(0:total_graph%nv)
		close(3)
		call get_time(end_time)
		elapsed_time = end_time-start_time
		write(unit=tmp1, fmt="(F10.6)")elapsed_time
		write (*, "(a)"), "Elapsed Time to read and construct graph: "//trim(adjustl(tmp1))//NEW_LINE('A')
		if (total_graph%nv < nproc) then
			write(unit=tmp1, fmt="(F10.6)")total_graph%nv
			write (*, "(a)"), "# of processes should be more than # of vertex: "//trim(adjustl(tmp1))
			call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
			call MPI_Finalize()
			call exit(-1)
		endif
		! print graph
		call print_CSR_graph( total_graph%nv, total_graph%ne, total_graph%nbr, total_graph%firstnbr )
	endif

	if (myrank.eq.0) then
		write(unit=tmp1, fmt=*)startvtx
		write(*,"(a)"), NEW_LINE('A')//"Starting vertex for BFS is " // trim(adjustl(tmp1)) // NEW_LINE('A')
	endif

	if (myrank.eq.0) call get_time(start_time)
	allocate(para_range_istart(0:nproc-1), para_range_iend(0:nproc-1))
	call sendrecv_graph (total_graph, nproc, myrank, para_range_istart, para_range_iend, my_graph, startvtx, value)
	if (myrank.eq.0) then
		deallocate(total_graph%firstnbr)
		deallocate(total_graph%nbr)
		call get_time(end_time)
		elapsed_time = end_time-start_time
	endif

	if (myrank.eq.0) call get_time(start2_time)
	allocate(levelsize(0:my_graph%nv-1))
	! traverse graph
	call pbfs( startvtx, my_graph, nproc, myrank, para_range_istart, para_range_iend, value, nlevelsp, levelsize )
	deallocate(para_range_istart, para_range_iend)
	if (myrank.eq.0) then
		call get_time(end_time)
		elapsed_time = end_time-start2_time
	endif

	if (myrank.eq.0) then
		reached = 0
		do i=0, nlevelsp-1
			reached = reached + levelsize(i)
		end do	
		write(unit=tmp1, fmt=*)startvtx
		write(unit=tmp2, fmt=*)nlevelsp
		write(unit=tmp3, fmt=*)reached
		write(*,"(a)"), "Breadth-first search from vertex "//trim(adjustl(tmp1))//" reached "//&
				trim(adjustl(tmp2))//" levels and "//trim(adjustl(tmp3))//" vertices."
		do i=0, nlevelsp-1
			write(unit=tmp1, fmt=*)i
			write(unit=tmp2, fmt=*)levelsize(i)
			write (*,"(a)"), "level "//trim(adjustl(tmp1))//" vertices: "//trim(adjustl(tmp2))
		end do

		write(unit=tmp1, fmt="(F10.6)")elapsed_time
		write (*, "(a)"), NEW_LINE('A')//"Elapsed Time to scatter graph data: "//trim(adjustl(tmp1))
		write(unit=tmp1, fmt="(F10.6)")elapsed_time
		write (*, "(a)"), "Elapsed Time to search: "//trim(adjustl(tmp1))
		elapsed_time = end_time-start_time
		if (elapsed_time.eq.0) then
			gteps = 0
		else
			gteps = (reached/elapsed_time)/1000000
		endif
		write(unit=tmp1, fmt="(F10.6)")elapsed_time
		write(unit=tmp2, fmt="(F10.6)")gteps
		write (*, "(a)"), "Total elapsed time: "//trim(adjustl(tmp1))// ", GTEPs: "//trim(adjustl(tmp2))
	endif

	call MPI_Finalize(ierr)

	deallocate(levelsize)
	deallocate(my_graph%nbr)
	deallocate(my_graph%firstnbr)
end program main

!c======================================================================
subroutine sendrecv_graph( total_graph, nproc, myrank, para_range_istart, para_range_iend, my_graph, startvtx, value)
    implicit none
    include 'mpif.h'

    type graph
        integer :: nv ! number of vertices
        integer*8 :: ne ! number of edges
        integer, allocatable :: nbr(:) ! array of neighbors of all vertices
        integer, allocatable :: firstnbr(:) ! index in nbr() of first neighbor of each vtx
    end type graph
	type (graph), intent(in out) :: total_graph
	integer, intent(in) :: nproc, myrank
	integer, intent(out) :: para_range_istart(0:nproc-1), para_range_iend(0:nproc-1)
	type (graph), intent(in out) :: my_graph
	real, intent(in out) :: startvtx
	real, intent(in out) :: value

	integer :: i, istart, iend, ierr, tmp1
	integer, allocatable :: sendcounts1(:), displs1(:), sendcounts2(:), displs2(:)

	call MPI_Bcast ( startvtx, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
	call MPI_Bcast ( total_graph%nv, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
	value = real(total_graph%nv) / real(nproc)
	if (myrank.eq.0) then
		allocate(sendcounts1(0:nproc-1))
		allocate(displs1(0:nproc-1))
		allocate(sendcounts2(0:nproc-1))
		allocate(displs2(0:nproc-1))
	endif
	do i=0,nproc-1
		call para_range( 0, total_graph%nv, nproc, i, istart, iend)
		para_range_istart(i) = istart
		para_range_iend(i) = iend
		if (i.ne.nproc-1) iend=iend+1
		tmp1 = iend-istart+1
		if (myrank.eq.0) then
			displs1(i) = istart
			sendcounts1(i) = tmp1
			displs2(i) = total_graph%firstnbr(istart) 
			sendcounts2(i) = total_graph%firstnbr(iend) - total_graph%firstnbr(istart)
		endif
		if (i.eq.myrank) then
			allocate(my_graph%firstnbr(0:tmp1-1))
			my_graph%nv = tmp1
		endif
	enddo
	call MPI_Scatterv ( total_graph%firstnbr(0:total_graph%nv), sendcounts1(0:nproc-1), displs1(0:nproc-1), &
			MPI_INTEGER, my_graph%firstnbr(0:(my_graph%nv-1)), my_graph%nv, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
	my_graph%ne = my_graph%firstnbr(my_graph%nv-1)-my_graph%firstnbr(0)	
	allocate(my_graph%nbr(0:my_graph%ne-1))
	call MPI_Scatterv ( total_graph%nbr(0:total_graph%ne-1), sendcounts2(0:nproc-1), displs2(0:nproc-1), &
			MPI_INTEGER, my_graph%nbr(0:my_graph%ne-1), my_graph%ne, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
	if (myrank.eq.0) then
		deallocate(sendcounts1)
		deallocate(sendcounts2)
		deallocate(displs1)
		deallocate(displs2)
	endif
	!write(*,*), myrank, " firstnbr: ", my_graph%firstnbr(0:my_graph%nv-1)
	!write(*,*), myrank, " nbr: ", my_graph%nbr(0:my_graph%ne-1)

end subroutine sendrecv_graph

!c======================================================================
subroutine pbfs( s, my_graph, nproc, myrank, para_range_istart, para_range_iend, value, nlevelsp, levelsize)
    implicit none
    include 'mpif.h'

	integer, parameter :: BUF_SIZE=2048

    type graph
        integer :: nv ! number of vertices
        integer*8 :: ne ! number of edges
        integer, allocatable :: nbr(:) ! array of neighbors of all vertices
        integer, allocatable :: firstnbr(:) ! index in nbr() of first neighbor of each vtx
    end type graph
	integer, intent(in) :: s ! starting vertex
	type (graph), intent(in) :: my_graph
	integer, intent(in) :: nproc, myrank
	integer, intent(in) :: para_range_istart(0:nproc-1), para_range_iend(0:nproc-1)
    real, intent(in) :: value
    integer, intent(out) :: nlevelsp
    integer, intent(in out) :: levelsize(0:my_graph%nv-1)

	integer :: startvtx, endvtx
	integer :: i, j, k, v, w, last_w, e, ierr
	integer :: back, front
	integer :: thislevel
	logical :: recvreq_active
	integer :: num_ranks_done, recvreq
	integer, allocatable :: level(:), queue(:)
	integer, allocatable :: sendbuf(:), recvbuf(:)
	integer, allocatable :: sendcnt(:), sendreqs(:)
	logical, allocatable :: sendreqs_active(:)

    ! get start and end vertex
    startvtx = para_range_istart(myrank)
    endvtx = para_range_iend(myrank)

	allocate(level(0:my_graph%nv-1), queue(0:my_graph%nv-1))
	allocate(sendbuf(0:nproc*BUF_SIZE-1))
	allocate(recvbuf(0:BUF_SIZE-1))
	allocate(sendcnt(0:nproc-1))
	allocate(sendreqs(0:nproc-1), sendreqs_active(0:nproc-1))

    ! initially, queue is empty, all levels are -1
    back = 0   ! position next element will be added to queue
    front = 0  ! position next element will be removed from queue
	levelsize(0) = 0
	do v=0, my_graph%nv-1
		level(v) = -1
	enddo
	do i=0,nproc-1
		sendreqs_active(i)=.false.
	enddo

    ! assign the starting vertex level 0 and put it on the queue to explore
    thislevel = 0
    call get_ranknum2(nproc, s, para_range_istart, para_range_iend, value, i)
    if (myrank.eq.i) then
        queue(back) = s
		back = back + 1
        levelsize(0) = 1
        level(s) = 0
    endif

    ! loop over levels, then over vertices at this level, then over neighbors
    do while(.true.) 
        levelsize(thislevel+1) = 0
		do i=0,nproc-1
            sendcnt(i) = 0
		enddo
		num_ranks_done = 1
		if (num_ranks_done.lt.nproc) then
			call MPI_IRECV(recvbuf, BUF_SIZE, MPI_INTEGER, MPI_ANY_SOURCE, 0, MPI_COMM_WORLD, recvreq, ierr)
			recvreq_active = .true.
		endif

		do i=0,levelsize(thislevel)-1
			call check_mpi_reqs( startvtx, thislevel, myrank, &
				nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
				recvreq, recvbuf, sendreqs_active, sendreqs, &
				num_ranks_done, queue, back, level, levelsize )
        	v = queue(front) ! v is the current vertex to explore from
			front=front+1
			last_w = -1
			do e=my_graph%firstnbr(v-startvtx), my_graph%firstnbr(v-startvtx+1)-1
            	w=my_graph%nbr(e-my_graph%firstnbr(0)) ! w is the current neighbor of v
            	if (w.eq.v.or.last_w.eq.w) cycle
				last_w = w
            	! w exists in current process
            	if (w.ge.startvtx.and.w.le.endvtx) then
                	if (level(w-startvtx).eq.-1) then ! w has not already been reached
                   		level(w-startvtx)=thislevel+1
                        levelsize(thislevel+1)=levelsize(thislevel+1)+1
                        queue(back) = w ! put w on queue to explore
						back = back + 1
                    endif
                else ! w exists in remote process
                	! get the rank # of w 
                    call get_ranknum2(nproc, w, para_range_istart, para_range_iend, value, j)
					do while(sendreqs_active(j)) 
						call check_mpi_reqs( startvtx, thislevel, myrank, &
							nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
							recvreq, recvbuf, sendreqs_active, sendreqs, &
							num_ranks_done, queue, back, level, levelsize )
					enddo
					sendbuf(j*BUF_SIZE + sendcnt(j)) = w
                    sendcnt(j)=sendcnt(j)+1
					if (sendcnt(j).eq.BUF_SIZE) then
						call MPI_ISEND(sendbuf(j*BUF_SIZE:), BUF_SIZE, MPI_INTEGER, &
							j, 0, MPI_COMM_WORLD, sendreqs(j), ierr)
						sendreqs_active(j) = .true.
						sendcnt(j) = 0
					endif
                endif
            enddo
		enddo
		do i=1,nproc-1
			e = mod(myrank+i, nproc)
			if (sendcnt(e).ne.0) then
				do while(sendreqs_active(e)) 
					call check_mpi_reqs( startvtx, thislevel, myrank, &
						nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
						recvreq, recvbuf, sendreqs_active, sendreqs, &
						num_ranks_done, queue, back, level, levelsize )
				enddo
				call MPI_ISEND(sendbuf(e*BUF_SIZE:), sendcnt(e), MPI_INTEGER, &
					e, 0, MPI_COMM_WORLD, sendreqs(e), ierr)
				sendreqs_active(e) = .true.
				sendcnt(e) = 0
			endif
			do while(sendreqs_active(e)) 
				call check_mpi_reqs( startvtx, thislevel, myrank, &
					nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
					recvreq, recvbuf, sendreqs_active, sendreqs, &
					num_ranks_done, queue, back, level, levelsize )
			enddo
			call MPI_ISEND(sendbuf(e*BUF_SIZE:), 0, MPI_INTEGER, &
				e, 0, MPI_COMM_WORLD, sendreqs(e), ierr)
			sendreqs_active(e) = .true.
			do while(sendreqs_active(e)) 
				call check_mpi_reqs( startvtx, thislevel, myrank, &
					nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
					recvreq, recvbuf, sendreqs_active, sendreqs, &
					num_ranks_done, queue, back, level, levelsize )
			enddo
		enddo
		do while(num_ranks_done.lt.nproc) 
			call check_mpi_reqs( startvtx, thislevel, myrank, &
					nproc, BUF_SIZE, my_graph%nv, recvreq_active, &
					recvreq, recvbuf, sendreqs_active, sendreqs, &
					num_ranks_done, queue, back, level, levelsize )
		enddo
        call MPI_Allreduce(MPI_IN_PLACE, levelsize(thislevel),1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)
        if (levelsize(thislevel).eq.0) exit
        thislevel = thislevel + 1
	enddo
	nlevelsp = thislevel
	deallocate(level, queue)
	deallocate(sendbuf, recvbuf)
	deallocate(sendcnt, sendreqs)
	deallocate(sendreqs_active)
end subroutine pbfs

!c======================================================================
subroutine check_mpi_reqs( startvtx, thislevel, myrank, nproc, BUF_SIZE, mynv, &
	recvreq_active, recvreq, recvbuf, sendreqs_active, sendreqs, &
	num_ranks_done, queue, back, level, levelsize )
	implicit none
	include 'mpif.h'
	integer, intent(in) :: startvtx, thislevel, myrank, nproc, BUF_SIZE, mynv
	logical, intent(in out) :: recvreq_active
	integer, intent(in out) :: recvreq
	integer, intent(in out) :: recvbuf(0:BUF_SIZE-1)
	logical, intent(in out) :: sendreqs_active(0:nproc-1)
	integer, intent(in out) :: sendreqs(0:nproc-1)
	integer, intent(in out) :: num_ranks_done
	integer, intent(in out) :: queue(0:mynv-1)
	integer, intent(in out) :: back
	integer, intent(in out) :: level(0:mynv-1)
	integer, intent(in out) :: levelsize(0:mynv-1)

	integer :: i, w, st_count, ierr
	logical :: flag
	integer st(MPI_STATUS_SIZE)

    do while(recvreq_active) 
		call MPI_TEST(recvreq, flag, st, ierr)
		if (flag) then
			recvreq_active = .false.
			call MPI_GET_COUNT(st, MPI_INTEGER, st_count, ierr)
			if (st_count.eq.0) then
				num_ranks_done = num_ranks_done + 1
			else 
				do i=0,st_count-1
					w = recvbuf(i)
	                if (level(w-startvtx).eq.-1) then ! w has not already been reached
                    	level(w-startvtx) = thislevel+1
                    	levelsize(thislevel+1) = levelsize(thislevel+1)+1
                    	queue(back) = w ! put w on queue to explore
						back = back + 1
           			endif
				enddo
			endif
			if (num_ranks_done.lt.nproc) then
				call MPI_IRECV(recvbuf, BUF_SIZE, MPI_INTEGER, MPI_ANY_SOURCE, 0, MPI_COMM_WORLD, recvreq, ierr)
				recvreq_active = .true.
			endif
		else
			exit
		endif
	enddo
	do i=0,nproc-1
		if (sendreqs_active(i)) then
			call MPI_TEST(sendreqs(i), flag, MPI_STATUS_IGNORE, ierr)
			if (flag) then
				sendreqs_active(i) = .false.
			endif
		endif
	enddo
end subroutine check_mpi_reqs

!c======================================================================
subroutine para_range( n1, n2, nproc, myrank, istart, iend)
	integer :: n1, n2, nproc, myrank
	integer :: istart, iend
	integer :: iw1, iw2	
	iw1 = (n2-n1+1)/nproc
	iw2 = mod(n2-n1+1, nproc)
	istart = myrank*iw1+n1+min(myrank,iw2)
	iend = istart+iw1-1
	if (iw2.gt.myrank) iend = iend+1 
end subroutine para_range

!c======================================================================
subroutine get_ranknum( nproc, vertex, para_range_istart, para_range_iend, rank)
	integer, intent(in) :: nproc, vertex, para_range_istart(0:nproc-1), para_range_iend(0:nproc-1)
	integer, intent(out) :: rank
    integer :: i
    rank = -1
	do i=0,nproc-1
        if (para_range_istart(i).le.vertex.and.para_range_iend(i).ge.vertex) then
            rank = i
            return
        endif
	enddo
end subroutine get_ranknum

!c======================================================================
subroutine get_ranknum2(nproc, vertex, para_range_istart, para_range_iend, value, rank)
	integer, intent(in) :: nproc, vertex, para_range_istart(0:nproc-1), para_range_iend(0:nproc-1)
	real, intent(in) :: value
	integer, intent(out) :: rank
    integer :: i
	integer :: j
	j = floor(vertex/value)
    if (para_range_istart(j).le.vertex.and.para_range_iend(j).ge.vertex) then
		rank = j
		return
	else if (para_range_istart(j).gt.vertex) then
		do i=j-1,0,-1
    		if (para_range_istart(i).le.vertex.and.para_range_iend(i).ge.vertex) then
				rank = i
				return
			endif
		enddo
	else
		do i=j+1,nproc-1
    		if (para_range_istart(i).le.vertex.and.para_range_iend(i).ge.vertex) then
				rank = i
				return
			endif
		enddo
	endif
    rank = -1
end subroutine get_ranknum2

!c======================================================================
subroutine bfs( s, nv, ne, nbr, firstnbr, nlevelsp, levelsize )
	integer, intent(in) :: s, nv
	integer*8, intent(in) :: ne
	integer, intent(in) :: nbr(0:ne-1), firstnbr(0:nv)
	integer, intent(out) :: nlevelsp
	integer, intent(out) :: levelsize(0:nv-1)

	integer :: thislevel, v, w, e
	integer :: back, front
	integer, allocatable :: level(:), queue(:)

	allocate(level(0:nv-1), queue(0:nv-1))
	! initially, queue is empty, all levels are -1
	back = 0 ! position next element will be added to queue
	front = 0 ! position next element will be removed from queue
	do v=0,nv-1
		level(v) = -1
	enddo

	! assign the starting vertex level 0 and put it on the queue to explore
	thislevel = 0
	level(s) = 0
	levelsize(0) = 1
	queue(back) = s
	back = back + 1

	! loop over levels, then over vertices at this level, then over neighbors
	do while(levelsize(thislevel) > 0) 
		levelsize(thislevel+1) = 0
		do i=0, levelsize(thislevel)-1 
			v = queue(front) ! v is the current vertex to explore from
			front = front + 1
			do e = firstnbr(v), firstnbr(v+1)-1
				w = nbr(e) ! w is the current neighbor of v
				if (level(w).eq.-1) then ! w has not already been reached
					level(w) = thislevel + 1
					levelsize(thislevel+1) = levelsize(thislevel+1)+1
					queue(back) = w ! put w on queue to explore
					back = back +1
				end if
			end do
		end do
		thislevel = thislevel + 1
	end do

	deallocate(level)
	deallocate(queue)
	nlevelsp = thislevel
end subroutine bfs

!c======================================================================
subroutine print_CSR_graph( nv, ne, nbr, firstnbr )
	implicit none
	integer :: nv, i
	integer*8 :: ne
	integer :: nbr(0:ne-1), firstnbr(0:nv)
	integer :: vlimit = 20
	integer :: elimit = 50
	character*80 tmp1,tmp2

	write(unit=tmp1, fmt=*)nv
	write(unit=tmp2, fmt=*)ne
	write(*,"(A)"), 'Graph has '//trim(adjustl(tmp1))//' vertices and '//trim(adjustl(tmp2))//' edges.'
	write(*,"(A)",advance="no"), 'fristnbr = '
	if (nv+1 < vlimit) vlimit = nv+1
	do i=0, vlimit-1
		write(unit=tmp1, fmt=*)firstnbr(i)
		write(*,'(A,A)',advance="no"), trim(adjustl(tmp1)), ' '
	enddo
	if (nv+1 > vlimit) write(*,'(A)',advance="no"), ' ...'
	write(*,*), ''
	if (ne < elimit) elimit = ne
	write(*,"(A)",advance="no"), 'nbr = '
	do i=0, elimit-1
		write(unit=tmp1, fmt=*)nbr(i)
		write(*,'(A,A)',advance="no"), trim(adjustl(tmp1)), ' '
	enddo
	if (ne > elimit) write(*,'(A)',advance="no"), ' ...'
	write(*,*), ''
end subroutine print_CSR_graph

!c======================================================================
subroutine get_time( time0 )
	implicit none	
	integer :: time_array_0(8)
	real :: time0

	call date_and_time(values=time_array_0)
    time0 = time_array_0 (5) * 3600 + time_array_0 (6) * 60 &
		+ time_array_0 (7) + 0.001 * time_array_0 (8)
	
end subroutine get_time